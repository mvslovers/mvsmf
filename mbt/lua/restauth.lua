-- The REST tests that need a password, run inside mbt (#400).
--
-- mbt never hands a password to another program, so a test of the logon
-- itself -- Basic auth, a wrong password, a logout, two logins -- cannot be a
-- shell suite any more. Here mbt sends the credentials and Lua only sees the
-- answers: ctx.mvs.request{ auth = "basic" | "none" | "token" } and
-- ctx.mvs.session{}, both in mbt's reference (ML02-0002, "The Table ctx").
--
--   auth          the z/OSMF authentication service, POST and DELETE
--                 /zosmf/services/authenticate. Was tests/curl-auth.sh and
--                 tests/zowe-auth.sh, which asserted the same things on the
--                 wire, one through curl and one through the Zowe SDK.
--   info-cookie   the session cookie a Basic request gets back on any route
--                 (#324). Was section 7 of tests/curl-info.sh; the rest of
--                 that suite needs no password and stayed there.
--
-- Neither touches mbt's own session, which every shell suite of the run
-- shares: each login here is logged off by the test that made it.

local check = require("restcheck")

local AUTH_PATH = "/zosmf/services/authenticate"
-- A gated endpoint, to prove a token is (or is no longer) accepted.
local GATED = "/zosmf/restfiles/ds?dslevel=SYS1.**"

-- The LtpaToken2 value and the whole Set-Cookie line, or nil. mbt joins
-- several Set-Cookie headers with a newline.
local function ltpa_cookie(headers)
  local sc = (headers and headers["set-cookie"]) or ""
  for line in (sc .. "\n"):gmatch("([^\n]*)\n") do
    local v = line:match("^%s*LtpaToken2=([^;]*)")
    if v then return v, line end
  end
  return nil
end

local function json_number(body, key)
  return (body or ""):match('"' .. key .. '"%s*:%s*(%-?%d+)')
end

local function json_string(body, key)
  return (body or ""):match('"' .. key .. '"%s*:%s*"([^"]*)"')
end

-- The alias of the ordinary user, when the target has one.
local function second_user(ctx)
  local tg = ctx.target()
  if tg.mvsmf.users and tg.mvsmf.users.test2 then return "test2" end
  return nil
end

-- A session of its own and its token, or nil, nil and why not. The reference
-- does not say whether a refused logon raises, so both steps are protected.
local function open_session(ctx, user)
  local ok, s = pcall(ctx.mvs.session, { user = user })
  if not ok then return nil, nil, s end
  local ok2, tok = pcall(function() return s:token() end)
  if not ok2 then return nil, nil, tok end
  if type(tok) ~= "string" or tok == "" then return nil, nil, "empty token" end
  return s, tok
end

local M = {}

function M.auth(ctx)
  local t = check.new(ctx, "mvsMF Authentication API - mbt (Lua) suite")
  local user2 = second_user(ctx)

  -- 1. Login with valid credentials -> 200, body, LtpaToken2 cookie, Path=/
  t.section("login (valid credentials)")
  local st, body, h = ctx.mvs.request{ method = "POST", path = AUTH_PATH,
                                       auth = "basic" }
  t.eq(200, st, "login returns 200")
  t.eq("0", json_number(body, "returnCode"), "login: returnCode")
  t.eq("0", json_number(body, "reasonCode"), "login: reasonCode")
  t.eq("Success.", json_string(body, "message"), "login: message")

  local token, line = ltpa_cookie(h)
  t.ok(token and #token > 0,
       "login: Set-Cookie LtpaToken2 present (" .. #(token or "") .. " chars)",
       "no LtpaToken2 in the response headers")
  -- Path=/ scopes the cookie to the whole /zosmf API -- a narrower path would
  -- silently break every request outside /zosmf/services.
  t.ok(line and line:find("; Path=/", 1, true), "login: cookie has Path=/",
       "missing Path=/: " .. tostring(line))

  -- 2. Replay the token on a gated endpoint, with nothing else
  t.section("token replay (cookie only)")
  if token then
    st = ctx.mvs.request{ path = GATED, auth = "token", token = token }
    t.eq(200, st, "gated endpoint accepts the LtpaToken2 cookie")
  else
    t.skip("token replay (no token captured)")
  end

  -- 3. Login without valid credentials -> 401 and the z/OSMF-shaped body
  t.section("login (invalid credentials)")
  -- Without any credential the request takes the same path through the
  -- handler as a wrong password (no ACEE -> 401, returnCode 8 / reasonCode 1),
  -- so the body is asserted here, and no userid's logon record is touched.
  st, body = ctx.mvs.request{ method = "POST", path = AUTH_PATH, auth = "none" }
  t.eq(401, st, "a login without credentials is rejected")
  if json_number(body, "returnCode") then
    t.eq("8", json_number(body, "returnCode"), "bad login: returnCode")
    t.eq("1", json_number(body, "reasonCode"), "bad login: reasonCode")
  else
    -- mvsMF's body appears only when httpd forwards the route (httpd#114).
    t.skip("bad login z/OSMF JSON body -- httpd front-gated the 401 (httpd#114)")
  end

  -- A real wrong password: one failed logon per run, and only for the
  -- ordinary test user -- never for the target's main user, which is usually
  -- an administrator.
  if user2 then
    st = ctx.mvs.request{ method = "POST", path = AUTH_PATH, auth = "basic",
                          user = user2, password = "WRONGPW" }
    t.eq(401, st, "a wrong password is rejected")
  else
    t.skip("wrong password (no further user test2 in the target)")
  end

  -- 4. Logout with the token -> 204, no body; the token dies with it
  t.section("logout")
  if token then
    st, body = ctx.mvs.request{ method = "DELETE", path = AUTH_PATH,
                                auth = "token", token = token }
    t.eq(204, st, "logout returns 204")
    t.ok(body == nil or body == "", "logout: empty body",
         "got: " .. tostring(body))
    st = ctx.mvs.request{ path = GATED, auth = "token", token = token }
    t.eq(401, st, "a logged-out token is rejected")
  else
    t.skip("logout (no token captured)")
  end

  -- 5. Logout without a valid token -> 401
  t.section("logout without a valid token")
  st = ctx.mvs.request{ method = "DELETE", path = AUTH_PATH, auth = "none" }
  t.eq(401, st, "logout without a token is rejected")
  st = ctx.mvs.request{ method = "DELETE", path = AUTH_PATH, auth = "token",
                        token = "bm90LWEtdG9rZW4=" }
  t.eq(401, st, "logout with a token nobody issued is rejected")

  -- 6. Two logins of one client are two sessions (httpd#288)
  --
  -- Same userid, same password, same address: before httpd#288 both got the
  -- SAME token, so logging one of them out ended the other. As the second
  -- user when the target has one, so that against an httpd without the fix
  -- this ends only that user's credential, not the one mbt's session runs on.
  t.section("two logins, one logout (httpd#288)")
  local a, ta, erra = open_session(ctx, user2)
  local b, tb, errb = open_session(ctx, user2)
  if not ta or not tb then
    t.fail("two logins: both return a token",
           "A: " .. tostring(erra or "ok") .. "  B: " .. tostring(errb or "ok"))
  else
    t.ok(ta ~= tb, "two logins: two different tokens",
         "both logins got the same token")
    t.eq(204, a:logout(), "two logins: logout of the first")
    t.eq(200, (b:request{ path = GATED }),
         "two logins: the second session survives the first's logout")
    t.eq(401, (ctx.mvs.request{ path = GATED, auth = "token", token = ta }),
         "two logins: the first token is dead")
    t.eq(204, b:logout(), "two logins: logout of the second")
  end

  return t.summary()
end

-- A Basic request on any route gets the session cookie back (#324 C1), with
-- the attributes that keep it out of scripts, and a caller presenting the
-- cookie gets none re-issued. The reference z/OSMF does both.
--
-- The cookie handed out here is the Basic cache's own, shared by every Basic
-- caller from this address (the residual of httpd#288), so it is not logged
-- off: that would end the cache entry, not a session of this test's.
function M.info_cookie(ctx)
  local t = check.new(ctx, "mvsMF Information service, session cookie - mbt (Lua) suite")

  t.section("implicit login (#324)")
  local st, _, h = ctx.mvs.request{ path = "/zosmf/info", auth = "basic" }
  t.eq(200, st, "Basic request on /zosmf/info")
  local token, line = ltpa_cookie(h)
  t.ok(token ~= nil, "Basic auth hands back the session cookie",
       "no Set-Cookie: LtpaToken2")
  t.ok(line and line:match("^%s*LtpaToken2=[^;]*; Path=/; HttpOnly; SameSite=Strict"),
       "the cookie carries Path, HttpOnly and SameSite",
       "attributes missing -- without HttpOnly the token is readable from JS: " ..
       tostring(line))

  -- A caller arriving with the cookie sends no Authorization, so nothing is
  -- re-issued. Absence is the assertion here.
  if token then
    local st2, _, h2 = ctx.mvs.request{ path = "/zosmf/info", auth = "token",
                                        token = token }
    t.eq(200, st2, "the cookie alone authenticates")
    t.ok(not (h2 and h2["set-cookie"]),
         "no cookie is re-issued to a caller that has one",
         "got: " .. tostring(h2 and h2["set-cookie"]))
  else
    t.skip("cookie replay (no cookie captured)")
  end

  return t.summary()
end

return M
