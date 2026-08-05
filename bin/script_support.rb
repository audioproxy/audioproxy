# frozen_string_literal: true

require "json"
require "open3"

# The docker and shell plumbing shared by the scripts in `bin/` that drive
# containers — and, more to the point, the one home for the comments explaining
# why each helper is shaped the way it is. Every one of them records a failure
# somebody already paid for, and three copies of that knowledge meant a
# correction to one left two stale, silently.
#
# Plumbing only, and that is the test for what belongs here: nothing below knows
# anything about audio, about memory, or about the proxy. The domain lives in
# `bin/capacity_model.rb` and stays there. A reader following the capacity
# argument does not need to know how `docker_run` picks a container id out by
# shape, and a reader wondering about that does not need the capacity model; one
# file would be the union of two audiences and the natural home for neither.
#
# Deliberately absent, because the copies differ and the differences are chosen:
# `log`, `step` and `check` are presentation, and `bin/smoke-image`'s `check`
# rescues an exception into a failure so one bad check does not abort the suite
# where `bin/check-capacity`'s deliberately does not; `await_health` dumps
# container state and the last forty log lines in one script and is a bounded
# poll in the other; `generate_fixtures` and `start_server` share names, not
# fixtures or environments.
#
# Not executable and not a script. `include ScriptSupport` into the script's
# main object — the helpers keep their state (the started-container registry,
# the last stderr) in the includer's instance variables.
module ScriptSupport
  # Returns [stdout, ok?]. stderr is kept OUT of the first element on purpose:
  # docker writes advisories there — "the requested image's platform does not
  # match the detected host platform" being the one that bites — and a caller
  # doing Float(out) or JSON.parse(out) then chokes on a warning it never asked
  # for. Folding the two together made every command that returns a *value* a
  # parsing hazard. stderr still reaches the failure message in `sh!`, where it
  # is the useful half.
  def sh(*args)
    stdout, stderr, status = Open3.capture3(*args)
    @last_stderr = stderr
    [stdout, status.success?]
  end

  def sh!(*args)
    out, ok = sh(*args)
    raise "command failed: #{args.join(" ")}\n#{out}#{@last_stderr}" unless ok

    out
  end

  # Every container started here is registered for teardown, so a failure
  # mid-suite does not strand one holding a published port. Scripts drain the
  # registry in an `ensure`.
  def containers = (@containers ||= [])

  # The id is picked out by shape rather than taken as "the output". `sh` keeps
  # stderr separate now, so this is belt-and-braces — but docker has been known
  # to put advisories on stdout too, and handing one of those to `docker inspect`
  # produces an error about a container that was in fact started correctly.
  def docker_run(*args)
    out = sh!("docker", "run", "-d", *args)
    cid = out.lines.map(&:strip).reverse.find { |line| line.match?(/\A[0-9a-f]{64}\z/) }
    raise "no container id in docker run output:\n#{out}" unless cid

    containers << cid
    cid
  end

  def docker_rm(cid)
    sh("docker", "rm", "-f", cid)
    containers.delete(cid)
  end

  # Docker picks the host port and we read back what it bound. Picking one here
  # first — bind port 0, read it, close, hand it over — leaves a window in which
  # anything on a busy runner can take it, and the failure looks like the proxy
  # rather than the race it is.
  def published_port(cid, container_port = 4000)
    ports = JSON.parse(sh!("docker", "inspect", cid)).first.dig("NetworkSettings", "Ports")
    binding = ports["#{container_port}/tcp"]&.first
    raise "container #{cid} published no host port for #{container_port}" unless binding

    Integer(binding["HostPort"])
  end

  # Runs one command in a fresh container of `image` and returns that
  # container's cgroup accounting, including the peak *anonymous* memory the
  # command made resident.
  #
  # cgroup v2 publishes a high-water mark for the cgroup as a whole
  # (`memory.peak`) and none for `anon`, so a shell loop inside the container
  # polls `memory.stat` while the command runs and the maximum is taken. The
  # sampler is in the cgroup it samples; callers that need it gone subtract a
  # baseline run carrying the same sampler, which cancels it.
  #
  # `interval` is a required keyword and not a default, because it is the number
  # that decides whether a sub-second encode is sampled tens of times or missed
  # between two polls — and because the two hand-written copies this replaced had
  # already drifted apart on exactly that value without either call site saying
  # so.
  #
  # `--cgroupns=private` is the default on a cgroup v2 host, and stated anyway:
  # with the host namespace the container would read the *host's* `memory.peak`,
  # which is a plausible-looking number about something else entirely.
  def sample_anon(image, cmd_argv, interval:)
    probe = <<~SH
      test -r /sys/fs/cgroup/memory.stat || { echo "cgroup=missing"; exit 0; }

      # One sample synchronously before the loop starts: a command that finishes
      # in milliseconds (a baseline's `true`) would otherwise be measured
      # against an empty sample file.
      : > /tmp/anon
      awk '$1 == "anon" {print $2}' /sys/fs/cgroup/memory.stat >> /tmp/anon

      while :; do
        awk '$1 == "anon" {print $2}' /sys/fs/cgroup/memory.stat >> /tmp/anon
        sleep $SAMPLE_INTERVAL
      done &
      sampler=$!

      "$@" > /dev/null 2>/tmp/cmd.err
      rc=$?
      kill "$sampler" 2>/dev/null

      echo "rc=$rc"
      echo "anon=$(sort -n /tmp/anon | tail -1)"
      echo "samples=$(wc -l < /tmp/anon)"
      echo "peak=$(cat /sys/fs/cgroup/memory.peak 2>/dev/null || echo 0)"
      echo "file=$(awk '$1 == "file" {print $2}' /sys/fs/cgroup/memory.stat)"
      tail -c 400 /tmp/cmd.err | tr '\\n' '~'
    SH

    out = sh!("docker", "run", "--rm", "--cgroupns=private",
              "-e", "SAMPLE_INTERVAL=#{interval}",
              "--entrypoint", "sh", image, "-c", probe, "sh", *cmd_argv)

    fields = out.lines.map(&:chomp)
    field = ->(name) { fields.find { |l| l.start_with?("#{name}=") }&.delete_prefix("#{name}=") }

    raise "this host exposes no cgroup v2 memory.stat" if field["cgroup"] == "missing"
    raise "#{cmd_argv.first} exited #{field["rc"]}:\n#{out}" unless field["rc"] == "0"

    anon = field["anon"].to_s
    raise "the sampler recorded nothing:\n#{out}" if anon.empty?

    {
      anon: Integer(anon),
      samples: Integer(field["samples"]),
      peak: Integer(field["peak"]),
      file: Integer(field["file"])
    }
  end
end
