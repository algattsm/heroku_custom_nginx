---------------------------------------------
-- PerimeterX(www.perimeterx.com) Nginx plugin
----------------------------------------------
local M = {}

function M.load(px_config)
    local _M = {}
    local ngx_HTTP_FORBIDDEN = ngx.HTTP_FORBIDDEN
    local ngx_HTTP_TOO_MANY_REQUESTS = ngx.HTTP_TOO_MANY_REQUESTS
    local ngx_HTTP_TEMPORARY_REDIRECT = 307

    local ngx_redirect = ngx.redirect
    local ngx_say = ngx.say
    local ngx_encode_args = ngx.encode_args
    local ngx_endcode_64 = ngx.encode_base64

    local px_template = require("px.block.pxtemplate").load(px_config)
    local px_client = require("px.utils.pxclient").load(px_config)
    local px_logger = require("px.utils.pxlogger").load(px_config)
    local px_headers = require("px.utils.pxheaders").load(px_config)
    local cjson = require "cjson"
    local px_constants = require "px.utils.pxconstants"
    local ngx_exit = ngx.exit
    local string_gsub = string.gsub

    local function is_accept_header_json(header)
        for h in string.gmatch(header, '[^,;]+') do
            if string.lower(h) == "application/json" then
                return true
            end
        end
        return false
    end

    local function inject_captcha_script(vid, uuid)
        return '<script type="text/javascript">window._pxVid = "' .. vid .. '";' ..
                'window._pxUuid = "' .. uuid .. '";</script>'
    end

    local function parse_action(action)
        if action == "c" then
            return "captcha"
        elseif action == "b" then
            return "block"
        elseif action == "j" then
            return "challenge"
        elseif action == "r" then
            return "ratelimit"
        else
            return "captcha"
        end
    end

    function _M.block(reason)
        local details = {}
        local ref_str = ''
        local vid = ''
        local uuid = ''
        local score = 0

        details.module_version = px_constants.MODULE_VERSION
        details.block_action = ngx.ctx.px_action
        if reason then
            details.block_reason = reason
            px_logger.enrich_log("pxblock", reason)
        end

        if ngx.ctx.uuid then
            uuid = ngx.ctx.uuid
            px_logger.enrich_log("pxuuid", ngx.ctx.uuid)
            details.block_uuid = uuid
        end

        if ngx.ctx.block_score then
            score = ngx.ctx.block_score
            details.block_score = score
        end

        if ngx.ctx.vid then
            vid = ngx.ctx.vid
            px_logger.enrich_log("pxvid", ngx.ctx.vid)
        end

        px_logger.enrich_log('pxaction', ngx.ctx.px_action)

        px_client.send_to_perimeterx('block', details)

        local should_bypass_monitor = px_config.bypass_monitor_header and px_headers.get_header(px_config.bypass_monitor_header) == '1'

        if (not px_config.block_enabled or ngx.ctx.monitored_route) and not should_bypass_monitor then
            -- end request inspection here and not block
            px_logger.debug("Blocking is not enabled, the request will not be blocked")
            return
        end

        -- mobile flow
        if ngx.ctx.px_cookie_origin == "header" then
            -- render captcha by default
            local block_action = parse_action(ngx.ctx.px_action)
            px_logger.debug("Enforcing action: " .. block_action .. " page is served")

            local html = px_template.get_template(ngx.ctx.px_action, details.block_uuid, vid)
            local collectorUrl = 'https://collector-' .. string.lower(px_config.px_appId) .. '.perimeterx.net'
            local result = {
                action = block_action,
                uuid = details.block_uuid,
                vid = vid,
                appId = px_config.px_appId,
                page = ngx.encode_base64(html),
                collectorUrl = collectorUrl
            }
            ngx.header["Content-Type"] = 'application/json'
            ngx.status = ngx_HTTP_FORBIDDEN
            ngx.say(cjson.encode(result))
            ngx_exit(ngx.OK)
            return
        end

        -- json response
        local accept_header = ngx.req.get_headers()["accept"] or ngx.req.get_headers()["content-type"]
        local is_json_response = px_config.advanced_blocking_response and accept_header and is_accept_header_json(accept_header) and not ngx.ctx.px_is_mobile
        if is_json_response then
            local props = px_template.get_props(px_config, details.block_uuid, vid, parse_action(ngx.ctx.px_action))
            local result = {
                appId = props.appId,
                jsClientSrc = props.jsClientSrc,
                firstPartyEnabled = props.firstPartyEnabled,
                vid = props.vid,
                uuid = props.uuid,
                hostUrl = props.hostUrl,
                blockScript = props.blockScript
            }
            ngx.header["Content-Type"] = 'application/json'
            ngx.status = ngx_HTTP_FORBIDDEN
            ngx.say(cjson.encode(result))
            ngx_exit(ngx.OK)
        end

        -- web scenarios
        ngx.header["Content-Type"] = 'text/html'

        -- render advanced actions (js challange/rate limit)
        if ngx.ctx.px_action ~= 'c' and ngx.ctx.px_action ~= 'b' then
            -- default status code
            ngx.status = ngx_HTTP_FORBIDDEN
            local action_name = parse_action(ngx.ctx.px_action)
            local body = ngx.ctx.px_action_data or px_template.get_template(action_name, uuid, vid)
            px_logger.debug("Enforcing action: " .. action_name .. " page is served")

            -- additional handling for actions (status codes, headers, etc)
            if ngx.ctx.px_action == 'r' then
                ngx.status = ngx_HTTP_TOO_MANY_REQUESTS
            end

            ngx_say(body)
            ngx_exit(ngx.OK)
            return
        end

        -- treat catpcha/block for each case
        if px_config.custom_block_url then
            -- custom block url, either custom block or redirect
            if px_config.redirect_on_custom_url then
                -- handling custom block url: create redirect url with original request url, vid and uuid as query params to use with captcha_api
                local req_query_param = ngx.req.get_uri_args()
                local enc_url, enc_args
                local original_req_url = ngx.var.uri
                if px_config.redirect_to_referer == true then
                    original_req_url = ngx.var.scheme .. "://" .. ngx.var.host .. ngx.var.uri
                end
                if req_query_param then
                    enc_args = ngx_encode_args(req_query_param)
                    enc_url = ngx_endcode_64(original_req_url .. '?' .. enc_args)
                end
                local redirect_url = px_config.custom_block_url .. '?url=' .. enc_url .. '&uuid=' .. uuid .. '&vid=' .. vid
                px_logger.debug('Redirecting to custom block page: ' .. redirect_url)
                ngx_redirect(redirect_url, ngx_HTTP_TEMPORARY_REDIRECT)
                return
            end

            local res = ngx.location.capture(px_config.custom_block_url)
            if res.truncated or res.status >= 300 then
                ngx.status = 500
                ngx_say('Unable to fetch custom block url. Status: ' .. tostring(res.status))
                ngx_exit(ngx.OK)
                return
            end

            local body = res.body
            if ngx.ctx.px_action == 'c' then
                -- inject captcha to the page
                px_logger.debug('Injecting captcha to page')
                body = string_gsub(res.body, '</head>', inject_captcha_script(vid, uuid) .. '</head>', 1)
                body = string_gsub(body, '::BLOCK_REF::', uuid)
            end
            ngx.status = ngx_HTTP_FORBIDDEN
            ngx_say(body)
            ngx_exit(ngx.OK)
            return
        end

        -- not custom block url, either api protection or default
        ngx.status = ngx_HTTP_FORBIDDEN
        if px_config.api_protection_mode then
            -- api protection mode
            local redirect_url = ngx.req.get_headers()['Referer']
            if redirect_url == nil or redirect_url == '' then
                redirect_url = px_config.api_protection_default_redirect_url
            end
            redirect_url = string.gsub(redirect_url, "https?://[^/]+", "")
            redirect_url = ngx_endcode_64(redirect_url)
            local url = px_config.api_protection_block_url .. '?url=' .. redirect_url .. '&uuid=' .. uuid .. '&vid=' .. vid
            local result = {
                reason = "blocked",
                redirect_to = url
            }
            ngx.header["Content-Type"] = 'application/json'
            ngx_say(cjson.encode(result))
            ngx_exit(ngx.OK)
            return
        end

        -- case: default px pages
        px_logger.debug("Enforcing action: " .. parse_action(ngx.ctx.px_action) .. " page is served")
        local html = px_template.get_template(ngx.ctx.px_action, uuid, vid)
        ngx_say(html)
        ngx_exit(ngx.OK)
        return
    end
    return _M
end

return M
