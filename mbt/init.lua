-- mvsMF's MVS tools, run as mbt commands: mbt run NAME [-- ARGS].
--
-- mbt owns the connection. The REST suites in tests/ and the Desktop deploy
-- get the target's mvsMF URL and user and the token of mbt's session in the
-- environment, which tests/lib/conn.sh reads; never a password (#400). The
-- token ends with the command, so nothing can outlive it or log on again.
-- What needs a password -- a Basic logon, a wrong one, a logout -- is in
-- mbt/lua/restauth.lua, where mbt sends the credentials itself.

local restauth = require("restauth")

-- The suites written in Lua, by the name `mbt run rest-tests` takes.
local LUA_SUITES = {
  ["auth"]        = restauth.auth,
  ["info-cookie"] = restauth.info_cookie,
  ["auth-refused"] = restauth.auth_refused,
}
local LUA_ORDER = { "auth", "info-cookie" }

-- auth-refused is in LUA_SUITES but not in LUA_ORDER: it adds and removes a
-- RAKF user and reloads the user table, so it is run by name, on a throwaway
-- container (#520).

-- Shell suites a full run leaves out: they are run by name, on purpose.
--   curl-diag     faults a worker on purpose, several times
--   curl-nospace  fills a volume to find its capacity
--   curl-jesspool rewrites SYS1.SECURE.CNTL(PROFILES) and reloads RAKF
--   curl-quiesce  stops HTTPD with P HTTPD; only for a throwaway container
local NOT_BY_DEFAULT = { ["curl-diag"] = true, ["curl-nospace"] = true, ["curl-jesspool"] = true, ["curl-quiesce"] = true, ["curl-consgate"] = true }

local function basename(p)
  return (p:match("([^/]+)%.sh$"))
end

-- tests/<name>.sh for every match of the pattern, sorted
local function scripts(ctx, pattern)
  local names = {}
  for _, p in ipairs(ctx.fs.list(pattern)) do
    local n = basename(p)
    if n then names[#names + 1] = n end
  end
  table.sort(names)
  return names
end

-- The connection a tool gets. With `second`, also the ordinary user's token,
-- from a session of its own, when the target has that user.
local function conn_env(ctx, second)
  local tg = ctx.target()
  local env = {
    MVSMF_URL   = tg.mvsmf.url,
    MVSMF_USER  = tg.mvsmf.user or "",
    MVSMF_TOKEN = ctx.mvs.token(),
  }
  if second and tg.mvsmf.users and tg.mvsmf.users.test2 then
    local s = ctx.mvs.session{ user = "test2" }
    env.MVSMF_USER2  = tg.mvsmf.users.test2
    env.MVSMF_TOKEN2 = s:token()
  end
  return env
end

-- Split `mbt run rest-tests -- ARGS` into suites and the arguments for them.
-- Names come first; the first word that is not a suite or a group, and every
-- word after it, goes to each shell suite: `-- curl-jobs --setup --cleanup`.
local function parse(ctx)
  local curl = scripts(ctx, "tests/curl-*.sh")
  local zowe = scripts(ctx, "tests/zowe-*.sh")
  local known = {}
  for _, n in ipairs(scripts(ctx, "tests/*.sh")) do known[n] = true end

  local function defaults(list)
    local out = {}
    for _, n in ipairs(list) do
      if not NOT_BY_DEFAULT[n] then out[#out + 1] = n end
    end
    return out
  end

  local groups = {
    lua  = LUA_ORDER,
    curl = defaults(curl),
    zowe = defaults(zowe),
  }

  local suites, args, seen = {}, {}, {}
  local function add(n)
    if not seen[n] then seen[n] = true; suites[#suites + 1] = n end
  end

  local i = 1
  while i <= #ctx.args do
    local a = ctx.args[i]
    if groups[a] then
      for _, n in ipairs(groups[a]) do add(n) end
    elseif a == "all" then
      for _, g in ipairs({ "lua", "curl", "zowe" }) do
        for _, n in ipairs(groups[g]) do add(n) end
      end
    elseif LUA_SUITES[a] or known[a] then
      add(a)
    else
      break
    end
    i = i + 1
  end
  for j = i, #ctx.args do args[#args + 1] = ctx.args[j] end

  if #suites == 0 then
    for _, g in ipairs({ "lua", "curl", "zowe" }) do
      for _, n in ipairs(groups[g]) do add(n) end
    end
  end
  return suites, args
end

mbt.command { name = "rest-tests",
  description = "the REST suites in tests/ against the target: [-- SUITE|lua|curl|zowe|all ... [ARGS]]",
  run = function(ctx)
    local suites, args = parse(ctx)

    if ctx.dry_run then
      ctx.log("would run: " .. table.concat(suites, " "))
      if #args > 0 then ctx.log("with: " .. table.concat(args, " ")) end
      return
    end

    local env = conn_env(ctx, true)
    if env.MVSMF_TOKEN == "" then
      error("the target's mvsMF gave mbt no session token")
    end
    if not env.MVSMF_USER2 then
      ctx.log("no further user test2 in the target: the non-admin sections skip")
    end

    local results = {}
    for _, name in ipairs(suites) do
      local passed
      if LUA_SUITES[name] then
        passed = LUA_SUITES[name](ctx)
      else
        local argv = { "bash", "tests/" .. name .. ".sh" }
        for _, a in ipairs(args) do argv[#argv + 1] = a end
        argv.env = env
        argv.check = false
        local _, code = ctx.exec(argv)
        passed = (code == 0)
      end
      results[#results + 1] = { name = name, passed = passed }
    end

    ctx.log("")
    ctx.log("==========================================")
    ctx.log(" Overall Results")
    ctx.log("==========================================")
    local failed = {}
    for _, r in ipairs(results) do
      ctx.log(string.format("  %-16s %s", r.name .. ":",
                            r.passed and "PASSED" or "FAILED"))
      if not r.passed then failed[#failed + 1] = r.name end
    end
    ctx.log("==========================================")
    if #failed > 0 then
      error(#failed .. " suite(s) failed: " .. table.concat(failed, ", "))
    end
  end }

mbt.command { name = "deploy-desktop",
  description = "tools/deploy-desktop.sh: upload static/ to the HTTPD UFS [-- --dry-run]",
  run = function(ctx)
    local argv = { "bash", "tools/deploy-desktop.sh" }
    for _, a in ipairs(ctx.args) do argv[#argv + 1] = a end
    if ctx.dry_run then
      ctx.log("would run: " .. table.concat(argv, " "))
      return
    end
    argv.env = conn_env(ctx)
    ctx.exec(argv)
  end }
