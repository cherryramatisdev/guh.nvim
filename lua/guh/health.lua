--- `:checkhealth guh` reports CLI availability, authentication, and rate-limit state for the
--- active provider (and notes the other backend when its CLI is installed).

local M = {}

local bins = { github = 'gh', gitlab = 'glab' }

local install_hint = {
  github = 'Install: https://cli.github.com',
  gitlab = 'Install: https://gitlab.com/gitlab-org/cli',
}

local login_hint = { github = 'Run: gh auth login', gitlab = 'Run: glab auth login' }

--- @param name 'github'|'gitlab'
--- @return boolean present
local function check_cli(name)
  local bin = bins[name]
  vim.health.start(('guh: %s CLI (%s)'):format(name, bin))
  if vim.fn.executable(bin) == 0 then
    vim.health.error(('`%s` not found on $PATH'):format(bin), { install_hint[name] })
    return false
  end
  local r = vim.system({ bin, '--version' }, { text = true }):wait()
  if r.code ~= 0 then
    vim.health.error(('`%s --version` failed: %s'):format(bin, vim.trim(r.stderr or '')))
    return false
  end
  vim.health.ok(vim.trim((r.stdout or ''):match('^[^\n]*') or (bin .. ' found')))
  return true
end

--- @param name 'github'|'gitlab'
--- @param mod table provider module.
--- @return boolean authed
local function check_auth(name, mod)
  vim.health.start(('guh: %s authentication'):format(name))
  local user = mod.get_user()
  if user then
    vim.health.ok(('logged in as %s'):format(user))
    return true
  end
  vim.health.error('not logged in', { login_hint[name] })
  return false
end

--- GitHub reports remaining quota via `gh api rate_limit`; GitLab has no equivalent endpoint.
local function check_github_rate_limit()
  vim.health.start('guh: GitHub API rate limit')
  local r = vim.system({ 'gh', 'api', 'rate_limit' }, { text = true }):wait()
  if r.code ~= 0 then
    vim.health.error('`gh api rate_limit` failed: ' .. vim.trim(r.stderr or ''))
    return
  end
  local ok, data = pcall(vim.json.decode, r.stdout)
  if not ok or not data.resources then
    vim.health.error('failed to parse rate_limit response')
    return
  end
  for name, rl in pairs(data.resources) do
    local msg = ('%-12s %d/%d, resets %s'):format(
      name,
      rl.remaining or 0,
      rl.limit or 0,
      rl.reset and os.date('%H:%M:%S', rl.reset) or '?'
    )
    if (rl.remaining or 0) == 0 then
      vim.health.error('rate-limited: ' .. msg)
    elseif (rl.remaining or 0) < (rl.limit or 1) * 0.1 then
      vim.health.warn(msg)
    else
      vim.health.info(msg)
    end
  end
end

--- @param name 'github'|'gitlab'
--- @param mod table provider module.
local function check_last_seen(name, mod)
  vim.health.start(('guh: %s last-seen rate-limit (passive)'):format(name))
  local rl = mod.rate_limit
  if not rl or not rl.limited then
    vim.health.ok('none')
    return
  end
  local when = rl.checked_at and (' at +%dms'):format(rl.checked_at) or ''
  vim.health.warn(('hit %s rate limit%s'):format(rl.kind or '?', when), { rl.message or '' })
end

--- @param name 'github'|'gitlab'
--- @param mod table provider module.
local function check_provider(name, mod)
  if not check_cli(name) then
    return
  end
  if not check_auth(name, mod) then
    return
  end
  if name == 'github' then
    check_github_rate_limit()
  else
    vim.health.start('guh: GitLab API rate limit')
    vim.health.info('GitLab exposes no rate-limit endpoint; only passive 429 detection is available')
  end
  check_last_seen(name, mod)
end

function M.check()
  local provider = require('guh.provider')
  local active = provider.current()
  local active_name = active == provider.get('github') and 'github' or 'gitlab'
  check_provider(active_name, active)

  -- Note the other backend, if its CLI is installed but not in use.
  for _, name in ipairs({ 'github', 'gitlab' }) do
    if name ~= active_name and vim.fn.executable(bins[name]) == 1 then
      vim.health.start(('guh: %s (installed, not active here)'):format(name))
      vim.health.info(
        ('`%s` found. Active provider is "%s"; set vim.g.guh_provider = "%s" to override.'):format(
          bins[name],
          active_name,
          name
        )
      )
    end
  end
end

return M
