# Exercise the release workflow against disposable Git remotes; nothing is published.
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require 'yaml'

ROOT = File.expand_path('../..', __dir__)
WORKFLOW = YAML.load_file(ENV.fetch('RELEASE_WORKFLOW', "#{ROOT}/.github/workflows/release-fork.yml"))
JOBS = WORKFLOW.fetch('jobs')
SHA_REF = '${{ needs.merge-upstream.outputs.source_sha }}'

ENV.update('GIT_AUTHOR_EMAIL' => 'test@example.com', 'GIT_AUTHOR_NAME' => 'Test',
           'GIT_COMMITTER_EMAIL' => 'test@example.com', 'GIT_COMMITTER_NAME' => 'Test',
           'GIT_CONFIG_GLOBAL' => File::NULL, 'GIT_CONFIG_NOSYSTEM' => '1')

def assert(condition, message)
  raise message unless condition
end

def command(*args, dir:, env: {}, success: true)
  output, status = Open3.capture2e(env, *args, chdir: dir)
  assert(status.success? == success, "#{args.first(3).join(' ')}: #{output}")
  output.strip
end

def git(*args, dir:)
  command('git', *args, dir: dir)
end

def step(job, name)
  JOBS.fetch(job).fetch('steps').find { |s| s['id'] == name || s['name'] == name } || raise("Missing #{name}")
end

def render(script, values)
  script.gsub(/\$\{\{\s*(.*?)\s*\}\}/) { values.fetch(Regexp.last_match(1)) }
end

def enabled(job, needs, dir:)
  expression = JOBS.fetch(job).fetch('if', 'success()')
  expression = "success() && (#{expression})" unless expression.match?(/(?:always|cancelled|failure|success)\(/)
  expression = expression.gsub(/needs\.([a-z-]+)/) { "needs[#{Regexp.last_match(1).to_json}]" }
  js = "const needs = #{JSON.generate(needs)}; const always = () => true; " \
       "const success = () => Object.values(needs).every(n => n.result === 'success'); " \
       "process.stdout.write(String(#{expression}));"
  command(ENV.fetch('NODE', 'node'), '-e', js, dir: dir) == 'true'
end

def commit(dir, path, content)
  FileUtils.mkdir_p(File.dirname("#{dir}/#{path}"))
  File.write("#{dir}/#{path}", content)
  git('add', '.', dir: dir)
  git('commit', '-m', content, dir: dir)
  git('rev-parse', 'HEAD', dir: dir)
end

Dir.mktmpdir('runner-source-') do |tmp|
  seed, origin, upstream = %w[seed origin upstream].map { |name| "#{tmp}/#{name}" }
  FileUtils.mkdir_p(seed)
  git('init', '-b', 'main', dir: seed)
  commit(seed, '.github/workflows/fixture.yml', 'fork workflow')
  event_sha = commit(seed, 'source.txt', 'event source')
  git('clone', '--bare', seed, origin, dir: tmp)
  commit(seed, 'source.txt', 'merged source')
  commit(seed, '.github/workflows/fixture.yml', 'upstream workflow')
  git('clone', '--bare', seed, upstream, dir: tmp)
  merge_step = JOBS.fetch('merge-upstream').fetch('steps').find { |s| s['name'] == 'Merge upstream' }
  merge_script = merge_step.fetch('run').gsub('https://github.com/falcondev-oss/github-actions-runner', upstream)

  run_merge = lambda do |name, expected_success|
    checkout = "#{tmp}/#{name}"
    git('clone', origin, checkout, dir: tmp)
    # Match checkout by immutable SHA as well as checkout's normal branch mode.
    git('checkout', '--detach', 'HEAD', dir: checkout)
    yield_path = "#{tmp}/#{name}.output"
    File.write(yield_path, '')
    [checkout, yield_path, lambda do
      command('bash', '-e', '-o', 'pipefail', '-c', merge_script, dir: checkout,
              env: { 'GITHUB_OUTPUT' => yield_path }, success: expected_success)
    end]
  end

  checkout, output, run = run_merge.call('merged', true)
  run.call
  source_sha = File.read(output).lines.find { |line| line.start_with?('source_sha=') }&.split('=')&.last&.strip
  assert(source_sha == git('rev-parse', 'HEAD', dir: checkout), 'Merge must export the exact pushed HEAD')
  assert(source_sha != event_sha, 'Fixture must advance beyond the triggering commit')
  assert(git('rev-parse', 'main', dir: origin) == source_sha, 'Exported source must have been pushed')
  assert(File.read("#{checkout}/source.txt") == 'merged source', 'Must contain upstream source')
  assert(File.read("#{checkout}/.github/workflows/fixture.yml") == 'fork workflow', 'Must preserve fork workflows')
  merge_id = merge_step.fetch('id')
  assert(JOBS['merge-upstream']['outputs']['source_sha'] == "${{ steps.#{merge_id}.outputs.source_sha }}", 'Expose merge output to downstream jobs')
  puts 'PASS: merged source is exported after a successful push, including detached HEAD'

  noop, output, run = run_merge.call('noop', true)
  run.call
  assert(File.read(output).strip == "source_sha=#{source_sha}", 'No-op must still export the same source')
  puts 'PASS: already synchronized run retains a source SHA'

  raced, output, run = run_merge.call('raced', false)
  advanced = commit(noop, 'later.txt', 'main moved after source was selected')
  git('push', 'origin', 'HEAD:refs/heads/main', dir: noop)
  run.call
  assert(File.read(output).empty?, 'Rejected push must not export a publishable source')
  puts 'PASS: concurrent main update rejects the push and exports no source'

  %w[check build release publish-image].each do |job|
    config = JOBS.fetch(job)
    assert(Array(config['needs']).include?('merge-upstream'), "#{job} needs direct access to the source output")
    config.fetch('steps').select { |s| s['uses'].to_s.start_with?('actions/checkout@') }.each do |s|
      assert(s.fetch('with', {})['ref'] == SHA_REF, "#{job} must select the merged SHA, not the event or moving main")
    end
    git('fetch', 'origin', dir: checkout)
    git('checkout', '--detach', source_sha, dir: checkout)
    assert(git('rev-parse', 'HEAD', dir: checkout) != advanced, 'A later main push must not change a consumer')
  end
  puts 'PASS: all downstream checkouts remain on merged source after main advances'

  release = JOBS.fetch('release').fetch('steps').find { |s| s['name'].to_s.start_with?('Create ') }
  release_script = render(release.fetch('run'), 'github.repository' => 'fixture/runner', 'needs.check.outputs.version' => '1.2.3')
  bin = "#{tmp}/bin"
  FileUtils.mkdir_p(bin)
  File.write("#{bin}/gh", "#!/usr/bin/env ruby\nrequire 'json'\nFile.write(ENV.fetch('GH_ARGS'), JSON.generate(ARGV))\n")
  File.chmod(0755, "#{bin}/gh")
  args_path = "#{tmp}/gh.json"
  env = { 'GH_ARGS' => args_path, 'PATH' => "#{bin}:#{ENV.fetch('PATH')}", 'SOURCE_SHA' => source_sha }
  command('bash', '-e', '-o', 'pipefail', '-c', release_script, dir: checkout, env: env)
  args = JSON.parse(File.read(args_path))
  assert(args[args.index('--target') + 1] == source_sha && args.include?('--verify-tag'), 'Release must verify and target the merged commit')
  assert(git('rev-parse', 'v1.2.3', dir: origin) == source_sha, 'Release tag must point to the built commit')
  # Retry after tag creation is safe; an unrelated existing tag must be refused.
  command('bash', '-e', '-o', 'pipefail', '-c', release_script, dir: checkout, env: env)
  File.delete(args_path)
  git('update-ref', 'refs/tags/v1.2.3', event_sha, dir: origin)
  command('bash', '-e', '-o', 'pipefail', '-c', release_script, dir: checkout, env: env, success: false)
  assert(!File.exist?(args_path), 'A mismatched tag must stop before creating a release')
  assert(git('rev-parse', 'v1.2.3', dir: origin) == event_sha, 'Never overwrite an existing tag')
  puts 'PASS: release tags the selected commit; mismatched tags cannot be published or overwritten'

  check_script = render(step('check', 'check_version').fetch('with').fetch('script'),
                        'github.repository_owner' => 'fixture', 'github.event.repository.name' => 'runner')
  plan = lambda do |event, release_status, succeeds = true|
    js = <<~JS
      const context = { eventName: #{event.to_json} };
      const core = { setOutput: (key, value) => { outputs[key] = value; } };
      const outputs = {};
      const github = { rest: { repos: {
        getLatestRelease: async () => ({ data: { tag_name: 'v1.2.3' } }),
        getReleaseByTag: async () => {
          if (#{release_status} !== 200) throw Object.assign(new Error('release lookup'), { status: #{release_status} });
          return { data: { html_url: 'https://github.com/fixture/runner/releases/tag/v1.2.3' } };
        }
      } } };
      console.log = () => {};
      (async () => { #{check_script} })()
        .then(() => process.stdout.write(JSON.stringify(outputs)))
        .catch(error => { console.error(error); process.exitCode = 1; });
    JS
    output = command(ENV.fetch('NODE', 'node'), '-e', js, dir: tmp, success: succeeds)
    succeeds ? JSON.parse(output) : nil
  end
  [403, 500].each { |status| plan.call('schedule', status, false) }
  puts 'PASS: release API failures stay failures rather than becoming no-op or publishing decisions'

  [ ['schedule', 200, false, false], ['schedule', 404, true, true],
    ['push', 200, true, false], ['workflow_dispatch', 200, true, false], ['push', 404, true, true] ].each do |event, status, should_build, should_release|
    outputs = plan.call(event, status)
    needs = { 'check' => { 'outputs' => outputs, 'result' => 'success' },
              'merge-upstream' => { 'result' => 'success' } }
    assert(enabled('build', needs, dir: tmp) == should_build, "#{event}/#{status}: incorrect build decision")
    needs['build'] = { 'result' => should_build ? 'success' : 'skipped' }
    release_enabled = enabled('release', needs, dir: tmp)
    assert(release_enabled == should_release, "#{event}/#{status}: existing releases must remain untouched")
    needs['release'] = { 'result' => release_enabled ? 'success' : 'skipped' }
    assert(enabled('publish-image', needs, dir: tmp) == should_build, "#{event}/#{status}: preserve image-only updates and quiet scheduled no-ops")
    runtimes = JSON.parse(outputs.fetch('build_matrix')).fetch('include').map { |m| m.fetch('runtime') }
    expected = should_release ? %w[linux-arm linux-arm64 linux-x64 osx-arm64 osx-x64] : %w[linux-arm64 linux-x64]
    assert(runtimes == expected, "#{event}/#{status}: only build required platforms")
    %w[build check merge-upstream].each do |failed|
      broken = Marshal.load(Marshal.dump(needs))
      broken[failed]['result'] = 'failure'
      assert(!enabled('publish-image', broken, dir: tmp), "Never publish after #{failed} fails")
    end
    needs['release']['result'] = 'failure'
    assert(!enabled('publish-image', needs, dir: tmp), 'Never publish after release creation fails')
  end
  assert(JOBS['build']['strategy']['matrix'] == '${{ fromJSON(needs.check.outputs.build_matrix) }}', 'Build the planned platform matrix')
  puts 'PASS: image-only pushes/manual runs build two fresh packages; new releases build five; unchanged schedules publish nothing'

  image = JOBS.fetch('publish-image')
  downloads = image.fetch('steps').select { |s| s['uses'].to_s.start_with?('actions/download-artifact@') }
  assert(downloads.map { |s| s['with']['name'] }.sort == %w[runner-packages-linux-arm64 runner-packages-linux-x64], 'Use Linux artifacts from this run')
  downloads.each do |download|
    config = download.fetch('with')
    assert(config['path'] == 'images/runner-packages' && !config.key?('run-id') && !config.key?('repository'), 'Keep package downloads scoped to this run and build context')
  end
  build = step('publish-image', 'build-and-push').fetch('with')
  assert(build['context'] == './images', 'Image must build from the pinned working tree')
  assert(build['tags'].include?("sha-#{SHA_REF}") && !build['tags'].include?('github.sha'), 'Image tag must identify its source')
  assert(build['labels'].include?("org.opencontainers.image.revision=#{SHA_REF}"), 'OCI revision must identify its source')
  %w[ARM64 X64].each { |arch| assert(build['build-args'].include?("RUNNER_PACKAGE_SHA256_#{arch}=${{ needs.build.outputs.linux-#{arch.downcase}-sha }}"), 'Package digest must come from this build') }
  assert(build['build-args'].include?('VERIFY_RUNNER_PACKAGE=true'), 'Published images must verify their packages')
  assert(build['build-args'].include?('RUNNER_PACKAGE_SOURCE=local'), 'Never download an older release package for publication')
  puts 'PASS: images consume this run\'s artifacts and identify the merged source'

  dockerfile = File.read(ENV.fetch('RUNNER_DOCKERFILE', "#{ROOT}/images/Dockerfile"))
  package_command = dockerfile.match(/RUN (?:--mount=.*?\\\n\s*)?export RUNNER_ARCH=.*?&& rm runner.tar.gz/m).to_s
  package_command = package_command.sub(/\ARUN (?:--mount=[^\n]*\n\s*)?/, '').gsub('/build-context', "#{tmp}/image-context")
  assert(!package_command.empty?, 'Exercise the real Dockerfile package preparation command')
  File.write("#{bin}/curl", "#!/bin/sh\ncp \"$PACKAGE_FIXTURE\" runner.tar.gz\ntouch \"$DOWNLOADED\"\n")
  File.write("#{bin}/tar", "#!/bin/sh\ntouch \"$EXTRACTED\"\n")
  FileUtils.chmod(0755, ["#{bin}/curl", "#{bin}/tar"])
  File.write("#{tmp}/package", 'package built from selected source')
  hash = Digest::SHA256.file("#{tmp}/package").hexdigest
  FileUtils.mkdir_p("#{tmp}/image-context/runner-packages")
  %w[arm64 x64].each { |arch| FileUtils.cp("#{tmp}/package", "#{tmp}/image-context/runner-packages/actions-runner-linux-#{arch}-1.2.3.tar.gz") }
  docker_env = { 'DOWNLOADED' => "#{tmp}/downloaded", 'EXTRACTED' => "#{tmp}/extracted", 'PACKAGE_FIXTURE' => "#{tmp}/package", 'PATH' => env['PATH'],
                 'RUNNER_PACKAGE_SHA256_ARM64' => hash, 'RUNNER_PACKAGE_SHA256_X64' => hash,
                 'RUNNER_REPOSITORY' => 'fixture/runner', 'RUNNER_VERSION' => '1.2.3', 'TARGETOS' => 'linux', 'VERIFY_RUNNER_PACKAGE' => 'true' }
  %w[local release].each do |mode|
    %w[amd64 arm64].each do |arch|
      selected_env = docker_env.merge('RUNNER_PACKAGE_SOURCE' => mode, 'TARGETARCH' => arch)
      FileUtils.rm_f("#{tmp}/downloaded")
      command('sh', '-ec', package_command, dir: tmp, env: selected_env)
      assert(File.exist?("#{tmp}/extracted"), 'Correct package must be extracted')
      assert(File.exist?("#{tmp}/downloaded") == (mode == 'release'), 'Local packages must never download old release assets')
      File.delete("#{tmp}/extracted")
      ['', '0' * 64].each do |bad_hash|
        bad_env = selected_env.merge('RUNNER_PACKAGE_SHA256_ARM64' => bad_hash, 'RUNNER_PACKAGE_SHA256_X64' => bad_hash)
        command('sh', '-ec', package_command, dir: tmp, env: bad_env, success: false)
        assert(!File.exist?("#{tmp}/extracted"), 'Missing or incorrect digest must prevent extraction')
      end
    end
  end
  FileUtils.rm_rf("#{tmp}/image-context/runner-packages")
  FileUtils.rm_f("#{tmp}/downloaded")
  command('sh', '-ec', package_command, dir: tmp,
          env: docker_env.merge('RUNNER_PACKAGE_SOURCE' => 'local', 'TARGETARCH' => 'amd64'), success: false)
  assert(!File.exist?("#{tmp}/downloaded") && !File.exist?("#{tmp}/extracted"), 'Missing local artifact must fail without falling back to a release')
  puts 'PASS: both architectures use fresh local packages; missing artifacts and bad checksums fail closed; standalone release downloads still work'

  provenance = step('publish-image', 'source-provenance')
  assert(provenance['env']['SOURCE_SHA'] == SHA_REF, 'Provenance must use the source output')
  predicate = { 'buildDefinition' => { 'resolvedDependencies' => [{ 'digest' => { 'gitCommit' => event_sha } }] } }
  js = "const core = { setOutput: (key, value) => process.stdout.write(value) };\n#{provenance['with']['script']}"
  output = command(ENV.fetch('NODE', 'node'), '-e', js, dir: tmp, env: {
    'GITHUB_REPOSITORY' => 'fixture/runner', 'GITHUB_SERVER_URL' => 'https://github.com',
    'PREDICATE' => JSON.generate(predicate), 'SOURCE_SHA' => source_sha
  })
  dependencies = JSON.parse(output).fetch('buildDefinition').fetch('resolvedDependencies')
  assert(dependencies.first['digest']['gitCommit'] == event_sha, 'Keep accurate workflow revision')
  assert(dependencies.find { |d| d['name'] == 'runner-source' }.fetch('digest')['gitCommit'] == source_sha, 'Attest the actual merged source')
  attest = step('publish-image', 'Generate attestation').fetch('with')
  assert(attest['predicate'] == '${{ steps.source-provenance.outputs.predicate }}', 'Sign the source-aware predicate')
  puts 'PASS: signed provenance distinguishes workflow revision from merged source'
end
