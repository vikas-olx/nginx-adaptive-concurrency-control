local timer_lib = require("timer")
local aimd_lib = require("aimd")
local gradient_lib = require("gradient")
local windowed_latency_lib = require("windowed_latency")

local setmetatable = setmetatable
local ngx_shared = ngx.shared
local assert = assert

-- in-flight requests
local ifr_key = 'ifr' 

-- concurrency limit
local limit_key = 'limit' 

local _M = {    
    _VERSION = '0.01'
}

local mt = {
    __index = _M
}

function _M.new(props)

    assert(props['limit_shm'] ~= nil, "Shared dictionary (limit_shm) is not specified") 
    
    assert(props['initial_concurrency_limit'] ~= nil, "Initial concurrency limit (initial_concurrency_limit) is not specified") 
    assert(props['initial_concurrency_limit'] > 0, "Initial concurrency limit must be greater than 0") 
    assert(props['min_concurrency_limit'] ~= nil, "Min concurrency limit (min_concurrency_limit) is not specified") 
    assert(props['min_concurrency_limit'] > 0, "Min concurrency limit must be greater than 0") 
    assert(props['max_concurrency_limit'] ~= nil, "Max concurrency limit (max_concurrency_limit) is not specified") 
    assert(props['max_concurrency_limit'] > 0, "Max concurrency limit must be greater than 0") 

    assert(props['latency_props'] ~= nil, "Latency props (latency_props) not specified") 
    assert(props['latency_props']['window_size'] ~= nil, "Latency window size (latency_props.window_size) is not specified")
    assert(props['latency_props']['window_size'] > 0, "Latency window size must be greater than 0") 
    assert(props['latency_props']['min_requests'] ~= nil, "Latency window min requests (latency_props.min_requests) is not specified")
    assert(props['latency_props']['min_requests'] > 0, "Latency window min requests must be greater than 0") 
    assert(props['latency_props']['metric'] ~= nil, "Latency metric (latency_props.metric) is not specified")
    assert(props['latency_props']['metric'] == 'average' or props['latency_props']['metric'] == 'percentile', "Allowed values for latency metric are 'average' and 'percentile'")

    local percentile_val = 0
    if props['latency_props']['metric'] == 'percentile' then
        assert(props['latency_props']['percentile_val'] ~= nil, "Percentile value (latency_props.percentile_val) is not specified")
        assert(props['latency_props']['percentile_val'] >= 50 and props['latency_props']['percentile_val'] < 100, "Percentile value must be between [50, 99]") 
        percentile_val = props['latency_props']['percentile_val']
    end

    assert(props['algo_props'] ~= nil, "Algo props (algo_props) is not specified") 
    assert(props['algo_props']['algo'] ~= nil, "Algo (algo_props.algo) is not specified") 
    assert(props['algo_props']['algo'] == 'AIMD' or props['algo_props']['algo'] == 'Gradient', "Allowed values for algo are 'AIMD' and 'Gradient'")
    
    if props['algo_props']['algo'] == 'AIMD' then
        assert(props['algo_props']['timeout'] ~= nil, "Timeout for AIMD algo (algo_props.timeout) is not specified")
        assert(props['algo_props']['timeout'] > 0, "Timeout for AIMD algo must be greater than 0")

        if props['algo_props']['backoff_factor'] ~= nil then
            assert(props['algo_props']['backoff_factor'] >= 0.5 and props['algo_props']['backoff_factor'] < 1, "Backoff factor must be between [0.5, 1)") 
        end
    end

    if props['algo_props']['algo'] == 'Gradient' then
        assert(props['algo_props']['long_window'] ~= nil, "Long Window for Gradient algo (algo_props.long_window) is not specified")
        assert(props['algo_props']['long_window'] > 0, "Long Window for Gradient algo must be greater than 0")
    end

    local dict = ngx_shared[props['limit_shm']]
    if not dict then
        return nil, "shared dict for limit not found"
    end

    local windowed_latency = windowed_latency_lib.new(dict, props['latency_props']['metric'], percentile_val, props['latency_props']['min_requests'])

    local algo = get_algo(dict, props)

    local self = {
        dict = dict,
        dict_name = props['limit_shm'],
        initial = props['initial_concurrency_limit'] + 0,
        windowed_latency = windowed_latency,
        algo = algo,
        timer = nil
    }

    return setmetatable(self, mt)
end

function get_algo(dict, props)
    if props['algo_props']['algo'] == 'AIMD' then
        return aimd_lib.new(props['min_concurrency_limit'], props['max_concurrency_limit'], props['algo_props']['timeout'], props['algo_props']['backoff_factor'])
    else
        return gradient_lib.new(dict, props['min_concurrency_limit'], props['max_concurrency_limit'], props['algo_props']['long_window'])
    end
end

function _M.incoming(self)
    local dict = self.dict
    local initial = self.initial

    limit = dict:get(limit_key) or initial

    ifr, err = dict:incr(ifr_key, 1, 0)
    if not ifr then -- Fail-open if unable to record request
        return true
    end

    ngx.log(ngx.ERR, string.format("incoming: %d, limit: %d", ifr, limit))

    if ifr > limit then
        ifr, err = dict:incr(ifr_key, -1)
        if not ifr then
            return true -- Fail-open if unable to record request
        end
        ngx.log(ngx.ERR, string.format("rejected: %d, limit %d", ifr, limit))
        return nil, "rejected"
    end

    return true, ifr
end

function _M.leaving(self, req_latency)

    local dict = self.dict

    local ifr, err = dict:incr(ifr_key, -1)
    if not ifr then
        return nil, err
    end 

    self.windowed_latency:add(req_latency)
    return ifr
end

function _M.start(self)
    local handler = function ()
        local dict = self.dict

        local initial = self.initial
        local min = self.min
        local max = self.max
        local backoff = self.backoff
        local timeout = self.timeout

        local limit = dict:get(limit_key) or initial

        local windowed_latency, err = self.windowed_latency:get()
        if not windowed_latency then
            ngx.log(ngx.ERR, "No Adjustment:: " .. err)
            return nil, err
        end

        local num_requests = err

        local new_limit = self.algo:adjust(limit, windowed_latency)

        ngx.log(ngx.ERR, string.format("Adjustment:: limit:%d, num:%d, latency:%f new_limit: %d", limit, num_requests, windowed_latency, new_limit))

        local succ, err, forcible = dict:set(limit_key, new_limit)
        if not succ then
            return nil, err    
        end    
    end

    local options = {
        interval = 1,           -- expiry interval in seconds
        recurring = true,         -- recurring or single timer
        immediate = false,         -- initial interval will be 0
        detached = false,         -- run detached, or be garbagecollectible
        expire = handler,  -- callback on timer expiry
        shm_name = self.dict_name,   -- shm to use for node-wide timers
        key_name = "my_timer_key"      -- key-name to use for node-wide timers
    }

    self.timer = timer_lib(options, self)
end

return _M