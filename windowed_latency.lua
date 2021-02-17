local WindowedLatency = {}
WindowedLatency.__index = WindowedLatency

-- number of requests in adjustment window
local num_requests_key = 'num'

-- sum of latencies of all requests in adjustment window
local latency_sum_key = 'sum' 

-- key to track the latencies of all requests in adjustment window
-- Used for calculating percentiles
local latencies_key = 'latencies'

function WindowedLatency.new(dict, type, percentile_val, min_requests)

    ngx.log(ngx.ERR, "HELLO")

    assert((type == 'average' or type == 'percentile') and percentile_val >= 0 and percentile_val < 100 and min_requests > 0)

    local self = setmetatable({}, WindowedLatency)
    self.dict = dict
    self.type = type
    self.percentile_val = percentile_val
    self.min_requests = min_requests
    return self
end

function WindowedLatency:add(req_latency)
    if self.type == 'average' then
        self.dict:incr(num_requests_key, 1, 0)
        self.dict:incr(latency_sum_key, req_latency, 0)
    else 
        self.dict:rpush(latencies_key, req_latency)  
    end  
end

function WindowedLatency:get()
    if self.type == 'average' then
        local sum_of_latencies, err = self.dict:get(latency_sum_key)
        if not sum_of_latencies then
            return nil, 'Unable to retrieve sum of latencies in window: ' .. (err or "")
        end

        local num_requests, err = self.dict:get(num_requests_key)
        if not num_requests then
            return nil, 'Unable to retrieve number of requests in window: ' .. (err or "")
        end

        if num_requests < self.min_requests then
            return nil, string.format('No. of requests in window (%d) less than min required (%d)', num_requests, self.min_requests)
        end    

        local avg_latency = sum_of_latencies/num_requests
    
        self.dict:set(latency_sum_key, 0)
        self.dict:set(num_requests_key, 0) 

        return avg_latency, num_requests
    else
        local len, err = self.dict:llen(latencies_key)

        if len < self.min_requests then
            return nil, string.format('No. of requests in window (%d) less than min required (%d)', len, self.min_requests)
        end    

        latencies = {}    
        for i = 1, len do
            table.insert(latencies, i, self.dict:lpop(latencies_key))
        end

        table.sort(latencies)
        local idx = math.floor( len * self.percentile_val /100 )
        local percentile_latency = latencies[idx]

        return percentile_latency, len
    end
end    

return WindowedLatency
