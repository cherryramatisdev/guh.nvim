--- GitLab backend, driving the `glab` CLI.
---
--- Produces the same `PullRequest` / `CIJob` / `Comment` shapes as the GitHub backend, so the
--- render/UI layer (`guh.pr`, `guh.comments`, `guh.state`) is provider-agnostic. See
--- `lua/guh/provider/shared.lua` for the vocabulary both backends normalize into.
---
--- Reads go through `glab api` (REST v4) with the URL-encoded project path in the endpoint and an
--- explicit `--hostname`, so behaviour never depends on the CWD.

local shared = require('guh.provider.shared')
local state = require('guh.state')
local util = require('guh.util')

require('guh.types')

local f = string.format

local M = {}

--- Last-seen rate-limit status (see `guh.provider.github` for the same field).
--- @type { limited: boolean, kind?: string, checked_at?: integer, message?: string }
M.rate_limit = { limited = false }

-- Provider-neutral helpers, re-exported so `guh.gh` (the shim) can forward them.
M.state_hl = shared.state_hl
M.reaction_emoji = shared.gitlab_reaction_emoji
M.pr_state_label = shared.pr_state_label
M.ci_icon = shared.ci_icon

local parse_or_default = shared.parse_or_default
local reltime = shared.reltime

--- Features this provider supports.
--- @return table<string, boolean>
function M.caps()
  return {
    viewed_state = false, -- GitLab has no public per-file "viewed" API; `cv` collapses locally.
    admin_merge = false, -- `glab mr merge` has no `--admin` equivalent.
    reactions = true, -- award emoji
    notifications = true, -- to-dos
    multiline_comment = true, -- note `position.line_range`
    -- GitLab reports no diffstat, so `get_pr_data` fetches the diff too (it also saves a call).
    diff_in_pr_data = true,
  }
end

--- Per-repo web base URL ("https://host/group/proj"), learned from API `web_url` fields.
--- Needed because the git host and the web host may differ (e.g. git.ifoodcorp.com.br vs
--- code.ifoodcorp.com.br), and `M.get_url` must stay synchronous.
--- @type table<string, string>
local web_base = {}

--- Host of the most recently seen repo, for repo-less URLs (`guh://status`).
local last_host ---@type string?

--- URL-encodes a project path or file path for use as a single API path segment.
--- @param s string
local function enc(s)
  return (s:gsub('[^%w%._~-]', function(c)
    return f('%%%02X', c:byte())
  end))
end

--- @param repo string Project path.
--- @return string? host
local function host_of(repo)
  local entry = require('guh.provider').registered(repo)
  if entry and entry.host then
    last_host = entry.host
  end
  return entry and entry.host or nil
end

--- Builds `glab api` argv for a project-scoped endpoint.
---
--- @param repo string Project path.
--- @param endpoint string Endpoint below "projects/<id>/".
--- @param extra? string[] Extra argv (flags, `-f` fields).
--- @return string[]
local function proj_api(repo, endpoint, extra)
  local argv = { 'glab', 'api' }
  local host = host_of(repo)
  if host then
    vim.list_extend(argv, { '--hostname', host })
  end
  table.insert(argv, 'projects/' .. enc(repo) .. '/' .. endpoint)
  vim.list_extend(argv, extra or {})
  return argv
end

--- Builds `glab api` argv for a user-level (non-project) endpoint.
local function user_api(endpoint, extra)
  local argv = { 'glab', 'api' }
  if last_host then
    vim.list_extend(argv, { '--hostname', last_host })
  end
  table.insert(argv, endpoint)
  vim.list_extend(argv, extra or {})
  return argv
end

--- Runs `cmds` concurrently, invoking `on_done(results)` once all have completed.
--- `results[i]` is the `vim.SystemCompleted` for `cmds[i]`.
---
--- @param cmds string[][]
--- @param on_done fun(results: table[])
local function parallel(cmds, on_done)
  local n = #cmds
  if n == 0 then
    return on_done({})
  end
  local results, done = {}, 0
  for i, cmd in ipairs(cmds) do
    util.system(cmd, nil, function(r)
      results[i] = r
      done = done + 1
      if done == n then
        on_done(results)
      end
    end)
  end
end

--- JSON-decodes the stdout of `r`, or returns nil (and logs) on failure.
---
--- @param r vim.SystemCompleted
--- @param logname string
--- @return any?, string? err
local function decode(r, logname)
  if r.code ~= 0 then
    local err = vim.trim(r.stderr or '')
    util.log(logname .. ' failed', { code = r.code, err = err })
    return nil, err
  end
  local resp = parse_or_default(r.stdout, nil)
  if resp == nil then
    util.log(logname .. ' bad json', r.stdout)
    return nil, 'Unexpected response'
  end
  return resp
end

--- Remembers the web base for `repo` from any API `web_url`.
--- @param repo string
--- @param web_url string?
local function cache_web_base(repo, web_url)
  if not web_url then
    return
  end
  local base = web_url:match('^(https?://.-)/%-/') or web_url:match('^(https?://[^/]+/[^/]+.-)/?$')
  if base then
    web_base[repo] = base
    last_host = base:match('^https?://([^/]+)') or last_host
  end
end

--------------------------------------------------------------------------- mapping

--- Normalizes a GitLab MR state into the shared vocabulary, so `shared.state_hl` (which is keyed
--- by "Open"/"Closed"/"Merged") matches.
--- @param state string?
--- @return string
local function norm_state(state)
  if state == 'opened' then
    return 'OPEN'
  elseif state == 'closed' then
    return 'CLOSED'
  elseif state == 'merged' then
    return 'MERGED'
  end
  return (state or ''):upper()
end

--- Normalizes a GitLab job status into the shared CI vocabulary.
--- nil means "not finished yet" (rendered as ⏳).
--- @param status string?
--- @return string?
local function job_conclusion(status)
  if status == 'success' then
    return 'success'
  elseif status == 'failed' then
    return 'failure'
  elseif status == 'canceled' then
    return 'cancelled'
  elseif status == 'skipped' then
    return 'skipped'
  end
  return nil -- created / pending / running / manual / scheduled / preparing / waiting_for_resource
end

--- Maps GitLab pipeline jobs to the shared `CIJob` shape, dropping skipped jobs.
--- @param jobs table[]
--- @param pipeline_id integer?
--- @return CIJob[]
local function to_ci_jobs(jobs, pipeline_id)
  local out = {}
  for _, j in ipairs(jobs or {}) do
    if j.status ~= 'skipped' then
      table.insert(out, {
        databaseId = j.id,
        runId = vim.tbl_get(j, 'pipeline', 'id') or pipeline_id,
        name = j.name or '?',
        conclusion = job_conclusion(j.status),
        status = j.status,
        startedAt = j.started_at,
        url = j.web_url,
      })
    end
  end
  table.sort(out, function(a, b)
    local a_s = a.conclusion or a.status or '?'
    local b_s = b.conclusion or b.status or '?'
    if a_s ~= b_s then
      return a_s < b_s
    end
    return (a.name or '') < (b.name or '')
  end)
  return out
end

--- Aggregates `/award_emoji` into the shared `reactionGroups` shape.
--- @param emoji table[]
--- @return { content: string, reactors: { totalCount: integer } }[]
local function to_reactions(emoji)
  local counts, order = {}, {}
  for _, e in ipairs(emoji or {}) do
    local name = e.name
    if name then
      if not counts[name] then
        counts[name] = 0
        table.insert(order, name)
      end
      counts[name] = counts[name] + 1
    end
  end
  local out = {}
  for _, name in ipairs(order) do
    table.insert(out, { content = name, reactors = { totalCount = counts[name] } })
  end
  return out
end

--- Maps GitLab MR commits to the shared `PRCommit` shape.
--- @param commits table[]
--- @return PRCommit[]
local function to_commits(commits)
  local out = {}
  for _, c in ipairs(commits or {}) do
    local msg = c.message or ''
    local head, body = msg:match('^([^\n]*)\n?(.*)$')
    table.insert(out, {
      oid = c.id,
      committedDate = c.committed_date or c.created_at,
      messageHeadline = c.title or head or '',
      messageBody = (body or ''):gsub('^\n+', ''),
    })
  end
  return out
end

--- Flattens GitLab discussions into the flat `Comment[]` that `comments.to_threads` consumes.
---
--- Also returns the MR-overview notes (comments not anchored to the diff), which GitLab keeps in
--- the same discussions list.
---
--- @return Comment[] diff_comments
--- @return table[] overview_notes
--- @return integer n_threads
--- @return integer n_resolved
local function flatten_discussions(discussions, mr, repo)
  local out, overview = {}, {}
  local n_threads, n_resolved = 0, 0
  local head_sha = vim.tbl_get(mr, 'diff_refs', 'head_sha')
  local iid = mr.iid
  local base = web_base[repo]

  for _, d in ipairs(discussions or {}) do
    -- Drop system notes (label/commit/description changes).
    local notes = {}
    for _, n in ipairs(d.notes or {}) do
      if not n.system then
        table.insert(notes, n)
      end
    end
    if #notes > 0 then
      local first = notes[1]
      local is_diff = first.position ~= nil
      local resolved = first.resolvable and first.resolved == true or false
      if is_diff then
        n_threads = n_threads + 1
        if resolved then
          n_resolved = n_resolved + 1
        end
      end
      for i, n in ipairs(notes) do
        if not is_diff then
          table.insert(overview, {
            id = n.id,
            user = vim.tbl_get(n, 'author', 'username') or '?',
            body = (n.body or ''):gsub('\r', ''),
            updated_at = (n.updated_at or ''):gsub('%.%d+', ''),
            url = base and f('%s/-/merge_requests/%s#note_%s', base, iid, n.id) or '',
          })
        else
          local pos = n.position
          local new_line, old_line = pos.new_line, pos.old_line
          local lr = pos.line_range
          local right = new_line ~= nil
          local axis_line = right and new_line or old_line
          -- `line_range` (multiline) supersedes the single-line anchor.
          local start_line, end_line = axis_line, axis_line
          if lr then
            local s = lr.start or {}
            local e = lr['end'] or {}
            start_line = right and (s.new_line or old_line) or (s.old_line or new_line)
            end_line = right and (e.new_line or old_line) or (e.old_line or new_line)
          end
          -- GitLab exposes no hunk text; synthesize a header so off-diff (stale) threads still
          -- render in the "outdated"/"outside" sections instead of being dropped.
          local hunk = ''
          if old_line and new_line then
            hunk = f('@@ -%d +%d @@', old_line, new_line)
          elseif new_line then
            hunk = f('@@ -0 +%d @@', new_line)
          elseif old_line then
            hunk = f('@@ -%d +0 @@', old_line)
          end
          if end_line ~= nil then
            table.insert(out, {
              id = n.id,
              html_url = base and f('%s/-/merge_requests/%s#note_%s', base, iid, n.id) or '',
              user = { login = vim.tbl_get(n, 'author', 'username') or '?' },
              body = (n.body or ''):gsub('\r', ''),
              diff_hunk = hunk,
              path = pos.new_path or pos.old_path,
              end_line = end_line,
              start_line = start_line,
              side = right and 'RIGHT' or 'LEFT',
              updated_at = (n.updated_at or ''):gsub('%.%d+', ''),
              -- Regroup replies into their discussion (see `comments.to_threads`).
              in_reply_to_id = i > 1 and first.id or nil,
              -- A note made against an older head is stale; against the current head it anchors
              -- outside the visible diff. Matches the GitHub `isOutdated` semantics.
              outdated = pos.head_sha ~= nil and head_sha ~= nil and pos.head_sha ~= head_sha or false,
              resolved = resolved,
              in_head = pos.head_sha == nil or pos.head_sha == head_sha,
              thread_id = first.id,
              thread_node_id = d.id, -- discussion id (string), used by resolve/reply.
            })
          end
        end
      end
    end
  end
  return out, overview, n_threads, n_resolved
end

--- Builds the shared `PullRequest` shape from GitLab API responses.
--- @return PullRequest
local function to_pr(mr, project, commits, discussions, jobs, emoji, repo)
  local diff_comments, overview, n_threads, n_resolved = flatten_discussions(discussions, mr, repo)
  local head_sha = vim.tbl_get(mr, 'diff_refs', 'head_sha') or mr.sha
  cache_web_base(repo, mr.web_url)
  if project then
    cache_web_base(repo, project.web_url)
  end
  return {
    node_id = tostring(mr.id),
    number = mr.iid,
    title = mr.title,
    body = mr.description,
    author = {
      login = vim.tbl_get(mr, 'author', 'username') or '?',
      name = vim.tbl_get(mr, 'author', 'name'),
    },
    authorAssociation = nil, -- GitLab has no equivalent of GitHub's author association.
    state = norm_state(mr.state),
    isDraft = mr.draft == true or mr.work_in_progress == true,
    createdAt = mr.created_at,
    baseRefName = mr.target_branch,
    headRefName = mr.source_branch,
    headRefOid = head_sha,
    baseRefOid = vim.tbl_get(mr, 'diff_refs', 'base_sha'),
    defaultBranch = project and project.default_branch or nil,
    additions = nil, -- Patched by `get_pr_data` from the fetched diff (GitLab has no diffstat).
    deletions = nil,
    commits = to_commits(commits),
    ci_jobs = to_ci_jobs(jobs, vim.tbl_get(mr, 'head_pipeline', 'id')),
    reactions = to_reactions(emoji),
    viewed = vim.empty_dict(), -- Unsupported by GitLab; `cv` collapses locally only.
    file_paths = vim.empty_dict(),
    raw_comments = diff_comments,
    notes = overview, -- MR-overview comments, rendered by `M.pr_overview_cmds`.
    n_threads = n_threads,
    n_resolved = n_resolved,
    url = mr.web_url,
  }
end

--------------------------------------------------------------------------- reads

--- @param repo string "group/subgroup/project"
--- @param iid string|integer MR number.
--- @param cb fun(mr?: table, err?: string)
local function get_mr(repo, iid, cb)
  util.system(proj_api(repo, f('merge_requests/%s', iid)), nil, function(r)
    local mr, err = decode(r, 'get_mr')
    cb(mr, err)
  end)
end

--- Gets MR data (metadata + comments + commits + CI + reactions) and caches it on the `pr/` buf.
---
--- Signature-compatible with `guh.provider.github.get_pr_data`.
---
--- @param prnum string|integer
--- @param repo string
--- @param opts? { force?: boolean }
--- @param on_result fun(pr?: PullRequest, err?: string)
function M.get_pr_data(prnum, repo, opts, on_result)
  vim.validate('repo', repo, 'string')
  opts = opts or {}
  if not opts.force then
    local pr_data = state.get_pr_data(repo, prnum)
    if pr_data then
      return on_result(pr_data)
    end
  end
  get_mr(repo, prnum, function(mr, err)
    if not mr then
      return on_result(nil, err or f('MR !%s not found in "%s"', prnum, repo))
    end
    -- Metadata first (it carries the pipeline id), then everything else concurrently.
    local jobs_endpoint = vim.tbl_get(mr, 'head_pipeline', 'id')
        and f('pipelines/%s/jobs?per_page=100', vim.tbl_get(mr, 'head_pipeline', 'id'))
      or nil
    local cmds = {
      proj_api(repo, ''), -- project (default_branch, web_url)
      proj_api(repo, f('merge_requests/%s/discussions?per_page=100', prnum)),
      proj_api(repo, f('merge_requests/%s/commits?per_page=100', prnum)),
      proj_api(repo, f('merge_requests/%s/award_emoji', prnum)),
      M.pr_diff_cmd(prnum, repo),
    }
    local diff_idx = #cmds
    local jobs_idx = jobs_endpoint and (#cmds + 1) or nil
    if jobs_endpoint then
      cmds[jobs_idx] = proj_api(repo, jobs_endpoint)
    end
    parallel(cmds, function(rs)
      local project = parse_or_default(rs[1].stdout, nil)
      local discussions = parse_or_default(rs[2].stdout, {}) or {}
      local commits = parse_or_default(rs[3].stdout, {}) or {}
      local emoji = parse_or_default(rs[4].stdout, {}) or {}
      local jobs = jobs_idx and (parse_or_default(rs[jobs_idx].stdout, {}) or {}) or {}
      local pr = to_pr(mr, project, commits, discussions, jobs, emoji, repo)
      -- Fetch the diff here as well: GitLab reports no diffstat, and caching it lets
      -- `guh.pr.load_pr` skip its own `glab mr diff` call (it reuses `pr.diff_stdout`).
      if rs[diff_idx] and rs[diff_idx].code == 0 then
        pr.diff_stdout = rs[diff_idx].stdout
        pr.additions, pr.deletions = shared.diffstat(pr.diff_stdout)
      end
      state.set_b_key(assert(state.get_buf('pr', repo, prnum)), { 'guh', 'pr_data' }, pr)
      util.log('gitlab.get_pr_data', { comments = #pr.raw_comments, threads = pr.n_threads })
      on_result(pr)
    end)
  end)
end

--- Resolves the repo for `cwd`. Kept for interface symmetry with the GitHub backend; `guh.pr`
--- resolves repos via `guh.remote` instead.
---
--- @param cwd? string
--- @param on_done fun(repo?: string)
function M.get_repo(cwd, on_done)
  require('guh.remote').resolve(cwd, function(remote)
    on_done(remote and remote.path or nil)
  end)
end

--- Fetches a commit as a git patch (plus its full sha).
---
--- @param sha string
--- @param repo string
--- @param on_result fun(res?: { sha: string, lines: string[] }, err?: string)
function M.commit(sha, repo, on_result)
  parallel({
    proj_api(repo, f('repository/commits/%s', sha)),
    proj_api(repo, f('repository/commits/%s/diff', sha)),
  }, function(rs)
    local meta = parse_or_default(rs[1].stdout, nil)
    local diffs = parse_or_default(rs[2].stdout, nil)
    if not meta or not diffs then
      return on_result(nil, vim.trim(rs[1].stderr or rs[2].stderr or 'Commit not found'))
    end
    local lines = {}
    for _, d in ipairs(diffs) do
      local old = d.old_path or d.new_path
      local new = d.new_path or d.old_path
      table.insert(lines, f('diff --git a/%s b/%s', old, new))
      table.insert(lines, f('--- a/%s', d.new_file and '/dev/null' or old))
      table.insert(lines, f('+++ b/%s', d.deleted_file and '/dev/null' or new))
      for line in (d.diff or ''):gmatch('[^\n]+') do
        table.insert(lines, line)
      end
    end
    on_result({ sha = meta.id or sha, lines = lines })
  end)
end

--- Fetches a file's contents at `ref`.
---
--- @param path string
--- @param ref string
--- @param repo string
--- @param on_result fun(res?: { lines: string[] }, err?: string)
function M.file(path, ref, repo, on_result)
  -- `--placeholder` makes glab encode the value as a single path segment (so "/" -> %2F).
  -- NB: `ref` must go in the query string, NOT via `-f`: adding any field flag switches the
  -- request to POST.
  local argv = proj_api(repo, 'repository/files/:file/raw?ref=' .. enc(ref), {
    '--placeholder',
    'file=' .. path,
  })
  util.system(argv, nil, function(r)
    if r.code ~= 0 then
      return on_result(nil, vim.trim(r.stderr or ''))
    end
    on_result({ lines = vim.split(r.stdout, '\n', { plain = true }) })
  end)
end

--- True if `id` is a merge request (vs an issue).
--- @param id string|integer
--- @param repo string
--- @param cb fun(is_pr: boolean)
function M.probe_is_pr(id, repo, cb)
  util.system(proj_api(repo, f('merge_requests/%s', id)), nil, function(r)
    cb(r.code == 0)
  end)
end

--- `glab` argv to view an issue.
--- @return string[]
function M.issue_view_cmd(id, repo)
  return M.cmd(repo, 'issue', 'view', tostring(id), '--comments')
end

--- Extra jobs for the `pr/…` overview buffer (commits + discussion), rendered from `pr_data`.
---
--- The header/body is rendered by `guh.pr` from `pr_data` itself, so GitLab needs no `glab`
--- template command here.
---
--- @return GuhJob[]
function M.pr_overview_cmds(id, repo)
  return {
    function(_, on_stdout, _, on_exit)
      local pr = state.get_pr_data(repo, id)
      if pr then
        on_stdout(nil, { render_pr_extras(pr) })
      end
      on_exit()
    end,
  }
end

--- Renders the commits + discussion sections of the `pr/…` overview.
--- @param pr PullRequest
--- @return string
function render_pr_extras(pr)
  local lines = { f('\n## Commits (%d)\n', #(pr.commits or {})) }
  for _, c in ipairs(pr.commits or {}) do
    table.insert(
      lines,
      f('%s  %s  %s', (c.oid or ''):sub(1, 12), (c.committedDate or ''):sub(1, 10), c.messageHeadline or '')
    )
  end
  table.insert(lines, '\n## Discussion')
  local notes = pr.notes or {}
  if #notes == 0 then
    table.insert(lines, '\n*No comments*')
  else
    for _, n in ipairs(notes) do
      table.insert(lines, f('\n*%s — %s*\n', n.user or '?', reltime(n.updated_at)))
      table.insert(lines, n.body or '')
    end
  end
  return table.concat(lines, '\n')
end

--- Jobs for the `repo/…` overview buffer.
--- @return GuhJob[]
function M.repo_overview_cmds(repo)
  return {
    function(_, on_stdout, _, on_exit)
      parallel({
        proj_api(repo, ''),
        proj_api(repo, 'repository/commits?per_page=10'),
        proj_api(repo, 'repository/branches?per_page=4'),
        proj_api(repo, 'merge_requests?state=opened&per_page=10&order_by=updated_at'),
        proj_api(repo, 'issues?state=opened&per_page=10&order_by=updated_at'),
      }, function(rs)
        local project = parse_or_default(rs[1].stdout, {}) or {}
        cache_web_base(repo, project.web_url)
        local lines = {}
        table.insert(lines, '\nRecent commits:')
        for _, c in ipairs(parse_or_default(rs[2].stdout, {}) or {}) do
          table.insert(lines, f('  %s  %s', (c.id or ''):sub(1, 12), c.title or ''))
        end
        local base = web_base[repo] or ('https://' .. (host_of(repo) or 'gitlab.com') .. '/' .. repo)
        table.insert(lines, f('\nBranches (last-updated): %s/-/branches', base))
        for _, b in ipairs(parse_or_default(rs[3].stdout, {}) or {}) do
          table.insert(lines, f('  %s/-/tree/%s', base, b.name or ''))
        end
        table.insert(lines, '\nOpen MRs (last-updated):')
        for _, mr in ipairs(parse_or_default(rs[4].stdout, {}) or {}) do
          table.insert(lines, f('  %-7s%s', f('!%s', mr.iid), mr.title or ''))
        end
        table.insert(lines, '\nOpen issues (last-updated):')
        for _, i in ipairs(parse_or_default(rs[5].stdout, {}) or {}) do
          table.insert(lines, f('  %-7s%s', f('#%s', i.iid), i.title or ''))
        end
        on_stdout(nil, { table.concat(lines, '\n') })
        on_exit()
      end)
    end,
    M.cmd(repo, 'mr', 'list'), -- MRs awaiting the current user.
  }
end

--- `glab` argv to fetch a PR diff. `--raw` emits an unmodified git patch, which the shared
--- `comments.prepare_pr_diff`/`to_line_map` parsers consume directly.
--- @return string[]
function M.pr_diff_cmd(id, repo)
  return { 'glab', 'mr', 'diff', tostring(id), '--raw', '-R', repo }
end

--- `glab` argv to edit a PR/MR or issue.
--- @param kind 'pr'|'issue'
--- @return string[]
function M.edit_cmd(kind, id, repo)
  return M.cmd(repo, kind == 'issue' and 'issue' or 'mr', 'update', tostring(id))
end

--- Merge-method choices offered by `guh.pr.merge_pr`.
--- @return string[]
function M.merge_choices()
  return { 'squash', 'merge', 'rebase' }
end

--- Gets the GitLab web URL for a `guh://` buffer, or nil.
---
--- Synchronous: reads the per-repo `web_base` cache (populated from API `web_url` fields), and
--- falls back to the registered git host when the cache is cold.
---
--- @param buf integer Buffer id (0 for current buffer).
--- @return string?
function M.get_url(buf)
  local b = state.get_b_guh(buf) or {}
  if b.feat == 'status' then
    return 'https://' .. (last_host or 'gitlab.com') .. '/dashboard/todos'
  end
  if not b.repo then
    return nil
  end
  local base = web_base[b.repo] or ('https://' .. (host_of(b.repo) or 'gitlab.com') .. '/' .. b.repo)
  if b.feat == 'repo' then
    return base
  elseif b.feat == 'issue' then
    return f('%s/-/issues/%s', base, b.id)
  elseif b.feat == 'commit' then
    return f('%s/-/commit/%s', base, b.id)
  elseif b.feat == 'prdiff' then
    return f('%s/-/merge_requests/%s/diffs', base, b.id)
  elseif b.feat == 'pr' or b.feat == 'prcomments' or b.feat == 'prlogs' or b.feat == 'file' then
    return f('%s/-/merge_requests/%s', base, b.id)
  end
  return nil
end

--- `glab` argv with a `-R <repo>` suffix.
--- @return string[]
function M.cmd(repo, ...)
  vim.validate('repo', repo, 'string')
  local argv = { 'glab', ... }
  table.insert(argv, '-R')
  table.insert(argv, repo)
  return argv
end

--- @param logname string
--- @param method 'POST'|'PUT'|'DELETE'|'GET'
--- @param repo string
--- @param endpoint string Endpoint below "projects/<id>/".
--- @param fields { [1]: '-f'|'-F', [2]: string }[]
--- @param cb fun(resp: table)
local function api_call(logname, method, repo, endpoint, fields, cb)
  local extra = { '--method', method }
  for _, kv in ipairs(fields) do
    vim.list_extend(extra, kv)
  end
  local argv = proj_api(repo, endpoint, extra)
  util.log(logname .. ' request', argv)
  util.system(argv, nil, function(r)
    local resp = parse_or_default(r.stdout, { errors = {} })
    util.log(logname .. ' resp', resp)
    cb(resp)
  end)
end

--------------------------------------------------------------------------- writes

--- Posts a new diff comment, via `glab mr note create --file/--line`.
---
--- @param pr PullRequest (needs `number`)
--- @param side 'LEFT'|'RIGHT'|nil
function M.new_comment(pr, body, path, start_line, line, side, repo, cb)
  -- `--line` targets the new version of the file; `--old-line` a removed line. Ranges are
  -- "start:end".
  local range = (start_line and start_line ~= line) and f('%d:%d', start_line, line) or tostring(line)
  local argv = M.cmd(
    repo,
    'mr',
    'note',
    'create',
    tostring(pr.number),
    '-m',
    body,
    '--file',
    path,
    side == 'LEFT' and '--old-line' or '--line',
    range
  )
  util.log('new_comment request', argv)
  util.system(argv, nil, function(r)
    cb(r.code == 0 and {} or { errors = { { message = vim.trim(r.stderr or '') } } })
  end)
end

--- Replies to a comment thread, via `glab mr note create --reply`.
---
--- @param thread_id? string Discussion id (`Comment.thread_node_id`).
--- @param cb fun(resp: table)
function M.reply_to_comment(prnum, body, reply_to, repo, thread_id, cb)
  vim.validate('repo', repo, 'string')
  local argv = M.cmd(
    repo,
    'mr',
    'note',
    'create',
    tostring(prnum),
    '-m',
    body,
    '--reply',
    tostring(thread_id or reply_to)
  )
  util.log('reply_to_comment request', argv)
  util.system(argv, nil, function(r)
    cb(r.code == 0 and {} or { errors = { { message = vim.trim(r.stderr or '') } } })
  end)
end

--- Posts a top-level comment on an MR or issue overview.
---
--- @param kind 'pr'|'issue'
function M.new_top_comment(kind, id, repo, body, cb)
  local request = M.cmd(repo, kind == 'issue' and 'issue' or 'mr', 'note', 'create', tostring(id), '-m', body)
  util.log('new_top_comment request', request)
  util.system(request, nil, function(r)
    cb(r.code == 0, r.stderr)
  end)
end

--- Updates a note's body. GitLab scopes notes by MR, so `prnum` is required.
---
--- @param prnum string|integer MR number.
function M.update_comment(comment_id, body, repo, prnum, cb)
  vim.validate('repo', repo, 'string')
  vim.validate('prnum', prnum, 'number')
  api_call('update_comment', 'PUT', repo, f('merge_requests/%d/notes/%s', prnum, comment_id), {
    { '-f', 'body=' .. body },
  }, cb)
end

--- Deletes a note. GitLab scopes notes by MR, so `prnum` is required.
---
--- @param prnum string|integer MR number.
function M.delete_comment(comment_id, repo, prnum, on_done)
  vim.validate('repo', repo, 'string')
  vim.validate('prnum', prnum, 'number')
  local argv = proj_api(repo, f('merge_requests/%d/notes/%s', prnum, comment_id), { '--method', 'DELETE' })
  util.system(argv, nil, function(r)
    on_done(r.code == 0, r.code ~= 0 and vim.trim(r.stderr or '') or nil)
  end)
end

--- Resolves/unresolves a discussion. GitLab scopes discussions by MR, so `prnum` is required.
---
--- @param thread_node_id string Discussion id.
--- @param resolve boolean
--- @param repo string
--- @param prnum string|integer MR number.
function M.resolve_thread(thread_node_id, resolve, repo, prnum, on_done)
  vim.validate('thread_node_id', thread_node_id, 'string')
  vim.validate('repo', repo, 'string')
  vim.validate('prnum', prnum, 'number')
  local argv = proj_api(repo, f('merge_requests/%d/discussions/%s', prnum, thread_node_id), {
    '--method',
    'PUT',
    '-f',
    'resolved=' .. tostring(resolve),
  })
  util.system(argv, nil, function(r)
    on_done(parse_or_default(r.stdout, {}))
  end)
end

--- Unsupported by GitLab (no public per-file "viewed" API); a no-op so `cv` keeps working as a
--- local-only collapse.
function M.set_file_viewed(_, _, _, on_done)
  on_done({})
end

--- Sets the MR "Draft"/"Ready" state.
function M.set_pr_draft(id, repo, draft, cb)
  local cmd = M.cmd(repo, 'mr', 'update', tostring(id), draft and '--draft' or '--ready')
  util.system(cmd, nil, function(r)
    cb(r.code == 0, r.stderr or '')
  end)
end

--- Merges an MR.
---
--- GitLab merge strategy is a per-merge flag, and there is no `--admin` equivalent (see `caps()`).
---
--- @param method 'merge'|'squash'|'rebase'
function M.merge_pr(id, repo, method, subject, body, admin, cb)
  vim.validate('id', id, 'number')
  vim.validate('repo', repo, 'string')
  vim.validate('method', method, function(m)
    return m == 'merge' or m == 'squash' or m == 'rebase'
  end, "'merge'|'squash'|'rebase'")
  local cmd = M.cmd(repo, 'mr', 'merge', tostring(id), '--yes')
  if method == 'squash' then
    table.insert(cmd, '--squash')
  elseif method == 'rebase' then
    table.insert(cmd, '--rebase')
  end
  -- Only merge commits and squashes carry a message.
  local message = subject and (subject .. (body and body ~= '' and ('\n\n' .. body) or '')) or nil
  if message then
    if method == 'squash' then
      vim.list_extend(cmd, { '--squash-message', message })
    elseif method == 'merge' then
      vim.list_extend(cmd, { '--message', message })
    end
  end
  util.system(cmd, nil, function(r)
    cb(r.code == 0, r.stderr or '')
  end)
end

--- Submits a review.
---
--- GitLab has no "request changes" state: `approve` approves (posting `body` as a note first when
--- given), while `comment`/`request-changes` post a note.
---
--- @param action 'approve'|'request-changes'|'comment'
function M.review_pr(id, repo, action, body, cb)
  vim.validate('id', id, 'number')
  vim.validate('repo', repo, 'string')
  vim.validate('body', body, 'string', true)
  local note = vim.trim(body or '')
  if action == 'request-changes' and note ~= '' then
    note = 'Requesting changes:\n\n' .. note
  end
  local function approve()
    local cmd = M.cmd(repo, 'mr', 'approve', tostring(id))
    util.system(cmd, nil, function(r)
      cb(r.code == 0, r.stderr or '')
    end)
  end
  if action == 'approve' then
    if note == '' then
      return approve()
    end
    util.system(M.cmd(repo, 'mr', 'note', 'create', tostring(id), '-m', note), nil, function()
      approve() -- Approve even if the note fails; the approval is the primary action.
    end)
  else
    local cmd = M.cmd(repo, 'mr', 'note', 'create', tostring(id), '-m', note)
    util.system(cmd, nil, function(r)
      cb(r.code == 0, r.stderr or '')
    end)
  end
end

--------------------------------------------------------------------------- identity / notifications

local cached_user ---@type string?

--- Gets the active GitLab username. Synchronous; cached for the session.
--- @return string?
function M.get_user()
  if cached_user then
    return cached_user
  end
  local r = vim.system(user_api('user'), { text = true }):wait()
  if r.code == 0 then
    local user = parse_or_default(r.stdout, nil)
    cached_user = user and user.username or nil
  end
  return cached_user
end

--- Fetches pending to-dos as the `guh://status` notification list.
---
--- @param buf integer The `guh://status` buffer.
--- @param on_done fun(lines?: string[], err?: string)
function M.get_user_notifs(buf, on_done)
  util.system({ 'glab', 'todo', 'list', '--output', 'json' }, nil, function(r)
    local todos, err = decode(r, 'get_user_notifs')
    if not todos then
      return on_done(nil, err or 'Failed to fetch to-dos')
    end
    local map = vim.empty_dict() ---@type table<string, Notification>
    local groups, repos = {}, {}
    for _, t in ipairs(todos) do
      local project = vim.tbl_get(t, 'project', 'path_with_namespace')
      local iid = vim.tbl_get(t, 'target', 'iid')
      if project and iid then
        local slug = f('%s#%s', project, iid)
        map[slug] = {
          thread_id = t.id,
          is_pr = t.target_type == 'MergeRequest',
        }
        cache_web_base(project, vim.tbl_get(t, 'project', 'web_url'))
        if not groups[project] then
          groups[project] = {}
          table.insert(repos, project)
        end
        local title = vim.tbl_get(t, 'target', 'title') or t.body or ''
        table.insert(groups[project], f('  %s  %s', slug, title))
      end
    end
    table.sort(repos)
    local lines = { 'Notifications (pending to-dos):' }
    for _, repo in ipairs(repos) do
      vim.list_extend(lines, groups[repo])
      table.insert(lines, '')
    end
    if vim.api.nvim_buf_is_valid(buf) then
      state.set_b_key(buf, { 'guh', 'notifications' }, map)
    end
    on_done(lines)
  end)
end

--- Marks a to-do done. (One-way: GitLab has no "mark as unread".)
function M.set_notif_read(thread_id, on_done)
  util.system({ 'glab', 'todo', 'done', tostring(thread_id) }, nil, function(r)
    on_done(r.code == 0, r.code ~= 0 and vim.trim(r.stderr or '') or nil)
  end)
end

--------------------------------------------------------------------------- CI

--- Reruns CI: one job when `job_id` is given, else the whole pipeline.
--- @param run_id integer Pipeline id (`CIJob.runId`).
--- @param job_id? integer Job id (`CIJob.databaseId`).
function M.rerun_ci(run_id, repo, job_id, on_response)
  vim.validate('repo', repo, 'string')
  local endpoint
  if job_id then
    endpoint = f('jobs/%s/retry', job_id)
  elseif run_id then
    endpoint = f('pipelines/%s/retry', run_id)
  else
    return on_response(false, 'missing pipeline id ("R" to refresh)')
  end
  local argv = proj_api(repo, endpoint, { '--method', 'POST' })
  util.system(argv, nil, function(r)
    on_response(r.code == 0, r.stderr or '')
  end)
end

--- Fetches one CI job's log.
--- @param job_id integer
--- @param on_result fun(log?: string, error?: string)
function M.get_pr_ci_log(job_id, repo, on_result)
  local progress = util.new_progress_report('Loading CI log', 0)
  progress('running', nil, 'job %s', tostring(job_id))
  vim.validate('repo', repo, 'string')
  util.system(proj_api(repo, f('jobs/%s/trace', job_id)), nil, function(r)
    if r.code ~= 0 or util.is_empty(vim.trim(r.stdout or '')) then
      progress('failed')
      return on_result(nil, f('Log unavailable: %s', vim.trim(r.stderr or '')))
    end
    progress('success')
    on_result(vim.trim(r.stdout))
  end)
end

--- Concurrently fetches CI logs for `jobs`. See `guh.provider.github.get_pr_ci_logs`.
function M.get_pr_ci_logs(jobs, repo, skip, on_result)
  vim.validate('repo', repo, 'string')
  for _, job in ipairs(jobs) do
    if not (skip and skip(job)) then
      M.get_pr_ci_log(job.databaseId, repo, function(log, err)
        on_result(job, log, err)
      end)
    end
  end
end

--------------------------------------------------------------------------- rate limit

--- GitLab exposes no rate-limit endpoint equivalent to `gh api rate_limit`, so only the passive
--- detection in `M.note_rate_limit` is available.
---
--- @param on_done? fun(rate_limit: table)
function M.check_rate_limit(on_done)
  if on_done then
    on_done(M.rate_limit)
  end
end

--- Scans `glab` stderr for rate-limit errors (GitLab answers 429).
function M.note_rate_limit(stderr, code)
  if code == 0 or not stderr or stderr == '' then
    return
  end
  if stderr:match('429') or stderr:lower():find('rate limit', 1, true) then
    M.rate_limit = {
      limited = true,
      kind = 'primary',
      checked_at = vim.uv.now(),
      message = vim.trim(stderr),
    }
  end
end

M._to_ci_jobs = to_ci_jobs -- testing
M._flatten_discussions = flatten_discussions -- testing
M._to_pr = to_pr -- testing

return M
