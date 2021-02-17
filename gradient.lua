local Gradient = {}
Gradient.__index = Gradient

function Gradient.new(dict, min, max, long_window)    
    local self = setmetatable({}, Gradient)
    self.dict = dict
    self.min = min
    self.max = max
    self.long_window = long_window
    return self
end

function Gradient:long_rtt(latency)
    local count = self.dict:incr('exp_count', 1, 0)
    if count <= 10 then
        local sum = self.dict:incr('exp_sum', latency, 0)
        local value = sum/count
        self.dict:set('exp_val', value)
        return value
    else
        local prev_val = self.dict:get('exp_val')
        local factor = 2.0 / (self.long_window + 1)
        local new_val = prev_val * (1-factor) + latency * factor
        self.dict:set('exp_val', new_val)
        return new_val
    end
end    

function Gradient:adjust(current_limit, latency)

    local short_rtt = latency
    local long_rtt = self:long_rtt(latency)

    if long_rtt / short_rtt > 2 then
        self.dict:set('exp_val', long_rtt * 0.95)
    end
    
    local tolerance = 1.2
    local queue_size = 2
    local smoothing = 0.2

    local gradient = math.max( 0.5, math.min( 1, tolerance * long_rtt/short_rtt ) )
    local new_limit = current_limit * gradient + queue_size
    new_limit_smoothed = math.floor(current_limit * (1 - smoothing) + new_limit * smoothing)
    new_limit_smoothed = math.max( self.min, math.min( self.max, new_limit_smoothed ) )

    ngx.log(ngx.ERR, string.format("Adjustment:: limit:%d, latency:%f long_rtt: %f gradient: %f new_limit: %d new_limit_smooth: %d", limit, latency, long_rtt, gradient, new_limit, new_limit_smoothed))

    return new_limit_smoothed
end

return Gradient
