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
--   auth-refused  a login that httpd resolves but RACF no longer accepts
--                 sets no cookie (#520). By name only: it adds and removes a
--                 RAKF user and reloads the user table -- see the function.
--
-- Neither touches mbt's own session, which every shell suite of the run
-- shares: each login here is logged off by the test that made it.

local check = require("restcheck")

-- Paths are below /zosmf: mbt puts that in front itself, and percent-encodes
-- what is not in /?=&() or unreserved -- a '*' arrives as %2A.
local AUTH_PATH = "/services/authenticate"
-- A gated endpoint, to prove a token is (or is no longer) accepted. /info is
-- authenticated like every other route (#324) and cheap to answer.
local GATED = "/info"

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

-- How many LtpaToken2 cookies the response sets.
local function count_ltpa(headers)
  local sc = (headers and headers["set-cookie"]) or ""
  local n = 0
  for line in (sc .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^%s*LtpaToken2=") then n = n + 1 end
  end
  return n
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

  -- The handler sends the cookie itself; the implicit cookie of any Basic
  -- response (#324) must not repeat it, or the client gets two (#520).
  t.eq(1, count_ltpa(h), "login: exactly one LtpaToken2 cookie")

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
  local h401
  st, body, h401 = ctx.mvs.request{ method = "POST", path = AUTH_PATH,
                                    auth = "none" }
  t.eq(401, st, "a login without credentials is rejected")
  t.eq(0, count_ltpa(h401), "a rejected login sets no cookie (#520)")
  if json_number(body, "returnCode") then
    t.eq("8", json_number(body, "returnCode"), "bad login: returnCode")
    t.eq("1", json_number(body, "reasonCode"), "bad login: reasonCode")
  else
    -- No body to read. Either httpd answered the 401 itself (httpd#114), or
    -- mbt dropped it: before the fix for that, ctx.mvs.request returned an
    -- empty body on every status >= 400. curl sees mvsMF's body here (dev1,
    -- 2026-10-11), so on a current stand this skip is mbt's.
    t.skip("bad login z/OSMF JSON body -- empty 401 body (httpd#114, or an mbt without the 4xx body fix)")
  end

  -- A real wrong password: one failed logon per run, and only for the
  -- ordinary test user -- never for the target's main user, which is usually
  -- an administrator.
  if user2 then
    local hwp
    st, _, hwp = ctx.mvs.request{ method = "POST", path = AUTH_PATH,
                                  auth = "basic", user = user2,
                                  password = "WRONGPW" }
    t.eq(401, st, "a wrong password is rejected")
    t.eq(0, count_ltpa(hwp), "a wrong password sets no cookie (#520)")
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
  local st, _, h = ctx.mvs.request{ path = "/info", auth = "basic" }
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
    local st2, _, h2 = ctx.mvs.request{ path = "/info", auth = "token",
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

-- A login httpd resolves from its credential cache but RACF now refuses (#520).
--
-- httpd keeps the credential of an earlier Basic request, so a login that
-- arrives with the old password still resolves; http_new_session() then asks
-- RACF for a second logon and is refused. That answer is a 500 and must not
-- carry a cookie: the one it used to carry was the shared Basic credential's.
--
-- CHANGES THE SYSTEM UNDER TEST: it adds the RAKF user AUTH520, changes its
-- password, reloads the RAKF user table (RAKFUSER) twice more and removes the
-- user again. Run it by name, on a throwaway container, with a target whose
-- main user is a RAKF administrator (group RAKFADM):
--
--   mbt run rest-tests -- auth-refused
--
-- The new user is not one of the target's, so its Basic requests go through
-- curl with a password this test makes up and owns; nothing of the target's
-- is used.
local RF_USER = "AUTH520"
local RF_OLD  = "OLDPW520"
local RF_NEW  = "NEWPW520"

-- Submit JCL as the main user, wait for it to end and purge it.
-- Returns true when it ended CC 0000.
local function rf_job(ctx, jcl)
  local st, body = ctx.mvs.request{ method = "PUT", path = "/restjobs/jobs",
                                    body = jcl, content_type = "text/plain" }
  local name, id = json_string(body, "jobname"), json_string(body, "jobid")
  if st ~= 200 or not name or not id then return false end
  local path = "/restjobs/jobs/" .. name .. "/" .. id
  local ok = false
  for _ = 1, 60 do
    local _, b = ctx.mvs.request{ path = path }
    if json_string(b, "status") == "OUTPUT" then
      ok = json_string(b, "retcode") == "CC 0000"
      break
    end
    ctx.exec{ "sleep", "1" }
  end
  ctx.mvs.request{ method = "DELETE", path = path }
  return ok
end

local function rf_tso(ctx, cmd)
  return rf_job(ctx, table.concat({
    "//AUTH520T JOB (ACCT),'AUTH 520',CLASS=A,MSGCLASS=H,GROUP=RAKFADM",
    "//S1 EXEC PGM=IKJEFT01,REGION=4096K",
    "//SYSPRINT DD SYSOUT=*",
    "//SYSTSPRT DD SYSOUT=*",
    "//SYSTSIN DD *",
    " " .. cmd,
    "/*" }, "\n"))
end

local function rf_reload(ctx)
  return rf_job(ctx, table.concat({
    "//AUTH520R JOB (ACCT),'AUTH 520',CLASS=A,MSGCLASS=H,GROUP=RAKFADM",
    "//RAKFUSER EXEC RAKFUSER" }, "\n"))
end

-- A request of the made-up user through curl: status, headers (several
-- Set-Cookie joined by a newline, names in lower case) and body. Under
-- `mbt run` ctx.exec returns no output, so curl writes to files in .mbt/,
-- which ctx.fs reads back.
local RF_HEAD = ".mbt/auth520.head"
local RF_BODY = ".mbt/auth520.body"

local function rf_curl(ctx, method, path, password)
  local url = ctx.target().mvsmf.url .. "/zosmf" .. path
  ctx.fs.mkdir(".mbt")
  ctx.exec{ "curl", "-s", "-X", method, "-u", RF_USER .. ":" .. password,
            "-H", "X-CSRF-ZOSMF-HEADER: 1", "-D", RF_HEAD, "-o", RF_BODY,
            url, check = false }
  local head = ctx.fs.exists(RF_HEAD) and ctx.fs.read(RF_HEAD) or ""
  local body = ctx.fs.exists(RF_BODY) and ctx.fs.read(RF_BODY) or ""
  ctx.fs.remove(RF_HEAD)
  ctx.fs.remove(RF_BODY)
  local status = tonumber(head:match("^HTTP/%S+%s+(%d+)"))
  local h = {}
  for line in (head .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    local k, v = line:match("^([^:]+):%s*(.*)$")
    if k then
      k = k:lower()
      h[k] = h[k] and (h[k] .. (k == "set-cookie" and "\n" or ", ") .. v) or v
    end
  end
  return status, body, h
end

function M.auth_refused(ctx)
  local t = check.new(ctx, "mvsMF Authentication API, refused new session - mbt (Lua) suite")

  t.section("fixture: the user " .. RF_USER)
  rf_tso(ctx, "DELUSER " .. RF_USER)   -- left over from a crashed run; may fail
  local fixture = rf_tso(ctx, "ADDUSER " .. RF_USER .. " PASSWORD(" .. RF_OLD ..
                         ") DFLTGRP(USER) NOOPERATIONS") and rf_reload(ctx)
  if not fixture then
    t.fail("the fixture user could not be added",
           "needs a RAKF administrator as the target's main user")
    return t.summary()
  end
  t.pass("user added, RAKF user table reloaded")

  -- 1. The credential httpd will remember
  local st = rf_curl(ctx, "GET", "/info", RF_OLD)
  t.eq(200, st, "Basic request with the first password")

  -- 2. RACF stops accepting it; httpd's cache still holds it
  t.section("password changed behind httpd's back")
  if rf_tso(ctx, "ALTUSER " .. RF_USER .. " PASSWORD(" .. RF_NEW .. ")") and
     rf_reload(ctx) then
    t.pass("password changed, RAKF user table reloaded")
    local body, h
    st, body, h = rf_curl(ctx, "POST", AUTH_PATH, RF_OLD)
    -- Not asserted as 401: http_new_session() answers -1 for every reason,
    -- and the handler maps all of them to 500 (authapi.c).
    t.eq(500, st, "login with the old password is refused")
    t.eq("40", json_number(body, "reasonCode"), "refused login: reasonCode")
    t.eq(0, count_ltpa(h), "refused login: no LtpaToken2 cookie (#520)")
    t.ok(not h["set-cookie"], "refused login: no Set-Cookie at all",
         "got: " .. tostring(h["set-cookie"]))
  else
    t.fail("the password could not be changed")
  end

  -- 3. Put the system back, whatever happened above
  t.section("cleanup")
  t.ok(rf_tso(ctx, "DELUSER " .. RF_USER) and rf_reload(ctx),
       "user removed, RAKF user table reloaded",
       "remove " .. RF_USER .. " by hand and run RAKFUSER")

  return t.summary()
end

return M
