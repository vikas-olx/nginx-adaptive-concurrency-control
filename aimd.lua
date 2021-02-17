local AIMD = {}
AIMD.__index = AIMD

function AIMD.new(min, max, timeout, backoff)
    local self = setmetatable({}, AIMD)
    self.min = min
    self.max = max
    self.backoff = backoff
    self.timeout = timeout
    return self
end

function AIMD:adjust(current_limit, latency)
    if latency >= self.timeout then
        new_limit = math.max( self.min, math.ceil( current_limit * self.backoff ) )
    else
        new_limit = math.min( self.max, current_limit + 1 )  
    end

    return new_limit
end

return AIMD
