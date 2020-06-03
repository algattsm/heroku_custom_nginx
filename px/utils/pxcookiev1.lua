local PXCookie = require('px.utils.pxcookie')

local PXCookieV1 = PXCookie:new {}

function PXCookieV1:new(t)
    t = t or {}
    setmetatable(t, self)
    self.__index = self
    return t
end

function PXCookieV1:validate(data)
    local request_data = data.t .. data.s.a .. data.s.b .. data.u
    if data.v then
        request_data = request_data .. data.v
    end

    if data.a then
        request_data = request_data .. data.a
    end

    local request_data_ip = request_data .. self.px_headers.get_ip()
    if ngx.ctx.px_is_mobile == false then
        request_data_ip = request_data_ip .. ngx.var.http_user_agent
    end

    local digest_ip = self.hmac("sha256", self.cookie_secret, request_data_ip)
    digest_ip = self.px_common_utils.to_hex(digest_ip)

    -- policy with ip
    if digest_ip == string.upper(data.h) then
        self.px_logger.debug('cookie verification succeed with IP in signature')
        return true
    end

    local request_data_noip = request_data .. ngx.var.http_user_agent
    local digest_noip = self.hmac("sha256", self.cookie_secret, request_data_noip)
    digest_noip = self.px_common_utils.to_hex(digest_noip)

    -- policy with no ip
    if digest_noip == string.upper(data.h) then
        self.px_logger.debug('cookie verification succeed with no IP in signature')
        return true
    end
    self.px_logger.debug('Cookie HMAC validation failed, value without ip: ' .. digest_noip .. ' with ip: ' .. digest_ip .. ', user-agent: ' .. self.px_headers.get_header("User-Agent"))
    return false
end

function PXCookieV1:process()
    local cookie = ngx.ctx.px_orig_cookie
    if not cookie then
        local no_cookie_message = "no_cookie"
        if ngx.ctx.pxhd then
            no_cookie_message = "no_cookie_w_vid"
        end
        error({ message = no_cookie_message })
    end

    -- Decrypt AES-256 or base64 decode cookie
    local data
    if self.cookie_encrypted == true then
        local success, result = pcall(self.decrypt, self, cookie, self.cookie_secret)

        if not success then
            self.px_logger.debug("Could not decrpyt cookie - " .. result)
            error({ message = "cookie_decryption_failed" })
        end
        data = result["plaintext"]
    else
        local success, result = pcall(ngx.decode_base64, cookie)
        if not success then
            self.px_logger.debug("Could not decode b64 cookie - " .. result)
            error({ message = "cookie_decryption_failed" })
        end
        data = result
    end

    -- Deserialize the JSON payload
    local success, result = pcall(self.decode, self, data)
    if not success then
        self.px_logger.debug("Could not decode cookie")
        error({ message = "cookie_decryption_failed" })
    end

    local fields = result
    ngx.ctx.px_cookie = data
    ngx.ctx.px_cookie_hmac = fields.h

    if fields.u then
        ngx.ctx.uuid = fields.u
    end

    if fields.v then
        ngx.ctx.vid = fields.v
    end

    -- cookie expired
    ngx.ctx.cookie_timestamp = fields.t

    if fields.t and fields.t > 0 and fields.t / 1000 < os.time() then
        self.px_logger.debug('Cookie TTL is expired, value: ' .. data .. ', age: ' .. fields.t / 1000 - os.time())
        error({ message = "cookie_expired" })
    end

    -- Set the score header for upstream applications
    self.px_headers.set_score_header(fields.s.b)
    -- Set the score variable for logging

    -- Check bot score and block if it is >= to the configured block score
    if fields.s and fields.s.b then
        ngx.ctx.px_action = 'c'
        ngx.ctx.block_score = fields.s.b
    end

    if fields.s.b >= self.blocking_score then
        self.px_logger.debug("Visitor score is higher than allowed threshold: " .. fields.s.b)
        return false
    end

    -- Validate the cookie integrity
    local success, result = pcall(self.validate, self, fields)
    if not success or result == false then
        self.px_logger.debug("Could not validate cookie v1 signature - " .. data)
        error({ message = "cookie_validation_failed" })
    end

    if self:is_sensitive_route() then
        self.px_logger.debug("cookie verification passed, risk api triggered by sensitive route")
        error({ message = "sensitive_route" })
    end

    return true
end

return PXCookieV1