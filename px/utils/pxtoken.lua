local PXPayload = require "px.utils.pxpayload"

local PXToken = PXPayload:new{}

function PXToken:new(t)
    t = t or {}
    setmetatable(t, self)
    self.__index = self
    return t
end

return PXToken