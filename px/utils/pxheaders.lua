---------------------------------------------
-- PerimeterX(www.perimeterx.com) Nginx plugin
----------------------------------------------

local M = {}

function M.load(px_config)
    local _M = {}

    -- localized config
    local px_logger = require ("px.utils.pxlogger").load(px_config)
    local px_common_utils = require("px.utils.pxcommonutils")
    local cookie_secret = px_config.cookie_secret
    local string_gsub = string.gsub
    local string_format = string.format
    local string_byte = string.byte
    local hmac = require "resty.nettle.hmac"
    local score_header_enabled = px_config.score_header_enabled
    local score_header = px_config.score_header_name
    local ngx_req_clear_header = ngx.req.clear_header
    local ngx_req_set_header = ngx.req.set_header
    local ngx_req_get_headers = ngx.req.get_headers

    local function header_token()
        local remote_addr = _M.get_ip()
        local user_agent = ngx.var.http_user_agent or ""
        local data = remote_addr .. user_agent
        local digest = hmac("sha256", cookie_secret, data)
        return px_common_utils.to_hex(digest)
    end

    function _M.validate_internal_request()
        local px_internal = _M.get_header('px_internal')
        local req_header_token = header_token()
        if px_internal and px_internal == req_header_token then
            px_logger.debug('Request is internal. PerimeterX processing skipped.')
            return true
        end
        ngx.req.set_header('px_internal', req_header_token)
    end

    function _M.clear_protected_headers()
        local protected_headers = { score_header }
        for i=1, #protected_headers do
            ngx_req_clear_header(protected_headers[i])
        end
    end

    function _M.set_score_header(score)
        if score_header_enabled then
            ngx_req_set_header(score_header, score)
            return
        else
            return
        end
    end

    function _M.get_ip()
        if px_config.ip_headers ~= nil then
            for i, header in ipairs(px_config.ip_headers) do
                if _M.get_header(header) ~= nil then
                    return _M.get_header(header)
                end
            end
        end
        local ip = ngx.var.remote_addr
        return ip or ""
    end

    function _M.get_header(name)
        return ngx_req_get_headers()[name] or nil
    end

    return _M
end
return M
