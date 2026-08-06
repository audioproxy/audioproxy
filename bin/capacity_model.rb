# frozen_string_literal: true

# The published capacity model's constants and its one parser, in a single
# place, because everything in `bin/` that reasons about memory has to reason
# about the *same* memory.
#
# Two consumers today, pulling in opposite directions, which is exactly why this
# file exists:
#
#   * `bin/check-capacity` evaluates the model forwards — given a configuration,
#     what should the container peak at — and asserts the real container stays
#     under it.
#   * `bin/capacity-matrix` evaluates it backwards — given a memory limit, how
#     many slots fit — and writes the answer into docs/capacity.md.
#
# A matrix computed from a second copy of these numbers would be a matrix that
# can disagree with the guard, and the disagreement would surface as an operator
# sizing a container from a table CI does not check. There is one copy.
#
# Not a constant here: `BEAM_base` as `check-capacity` uses it. That guard
# *measures* the idle container rather than assuming it, deliberately — a guard
# carrying a hardcoded base silently absorbs base growth. `BEAM_BASE_BUDGET`
# below is the published figure, which is what a document has to quote and what
# the matrix has to predict from, and it is not what the guard asserts against.
module CapacityModel
  MIB = 1_048_576.0
  GIB = 1_073_741_824

  REPO_ROOT = File.expand_path("..", __dir__)
  CAPACITY_DOC = File.join(REPO_ROOT, "docs", "capacity.md")

  # `BEAM_base` as docs/capacity.md publishes it: the release at rest — ERTS,
  # the supervision tree, Bandit's acceptors — measured on the runtime image
  # idle and healthy.
  BEAM_BASE_BUDGET = 110 * 1024 * 1024

  # `T_ffmpeg` as docs/capacity.md publishes it: the library working set a
  # long-lived container holds resident once every format has been exercised.
  # Kept in step with that document's "budget 150 MiB" by hand — it is the one
  # constant here that is a judgement rather than a reading, which is exactly why
  # it is written down in both places rather than derived in one.
  T_FFMPEG_BUDGET = 150 * 1024 * 1024

  # `@high_water` in AudioProxy.Ffmpeg.Render.
  HIGH_WATER = 1 * 1024 * 1024

  # `@linger` in AudioProxy.RenderCoordinator is 1 s, and a completed render
  # holds its whole backlog for that second having already released its slot.
  # For renders taking tens of seconds, at most about one extra backlog is
  # resident. Short renders are the other case — see `linger_backlogs`.
  LINGER_BACKLOGS = 1

  # `AP_MAX_VARIANT_BYTES`'s default: the retention cap, which a render's
  # cumulative output crossing gets it killed and the request failed. It
  # defaults to the effective `AP_MAX_SRC_BYTES` — the same 2 GB when neither
  # is set — but it is the retention ceiling that decides a refusal, and the
  # source ceiling has nothing to say about output.
  DEFAULT_MAX_VARIANT_BYTES = 2_000_000_000

  # The boundary in the linger argument. A render that finishes in well under a
  # second turns its slot over inside the linger window, so a whole second's
  # worth of completed backlogs can be resident at once: budget `L = C`. Longer
  # renders make `L` a rounding error: budget `L = 1`. See "Why `C` is not
  # enough" in docs/capacity.md.
  SHORT_RENDER_SECONDS = 30

  module_function

  def mib(bytes) = (bytes / MIB).round(1)

  # How many full backlogs are resident at `C` concurrent renders of this
  # length — `C + L`, with `L` chosen by the linger argument above.
  def resident_renders(concurrency, output_seconds)
    if output_seconds <= SHORT_RENDER_SECONDS
      concurrency * 2
    else
      concurrency + LINGER_BACKLOGS
    end
  end

  # The per-render bracket of the published formula:
  # `R_ffmpeg + B_backlog + H_pipeline`.
  def per_render_bytes(r_ffmpeg:, backlog_bytes:)
    r_ffmpeg + backlog_bytes + HIGH_WATER
  end

  # The formula, forwards: what `C` concurrent renders of this shape cost.
  def ram_required(concurrency:, output_seconds:, r_ffmpeg:, backlog_bytes:,
                   beam_base: BEAM_BASE_BUDGET, ffmpeg_text: T_FFMPEG_BUDGET)
    renders = resident_renders(concurrency, output_seconds)
    beam_base + ffmpeg_text + (renders * per_render_bytes(r_ffmpeg:, backlog_bytes:))
  end

  # The formula, inverted: the largest `AP_MAX_CONCURRENCY` whose worst case
  # fits in `ram_budget`.
  #
  # The division floors — a fractional slot is not a slot — and the linger term
  # is subtracted rather than ignored, so the short-render rows stay honest
  # about needing `2C` worth of backlog. Returns 0 when a single render does not
  # fit, which is a real answer and not an error: it says this workload does not
  # run on this host at any concurrency.
  def max_concurrency(ram_budget:, output_seconds:, r_ffmpeg:, backlog_bytes:,
                      beam_base: BEAM_BASE_BUDGET, ffmpeg_text: T_FFMPEG_BUDGET)
    available = ram_budget - beam_base - ffmpeg_text
    return 0 if available <= 0

    # Integer division, and it floors: a partial slot is not a slot. Every term
    # here is whole bytes (see `published_rss` for why that is deliberate), so
    # this is exact rather than nearly exact — which is what lets the reverse
    # table and this function agree on the same cell.
    renders = available / per_render_bytes(r_ffmpeg:, backlog_bytes:)
    slots =
      if output_seconds <= SHORT_RENDER_SECONDS
        renders / 2
      else
        renders - LINGER_BACKLOGS
      end

    [slots, 0].max
  end

  # A render whose output crosses `AP_MAX_VARIANT_BYTES` is killed partway
  # through and the request fails, so this workload has no concurrency figure —
  # it has a refusal. See "Long-form lossless" in docs/capacity.md.
  def refused?(backlog_bytes, max_variant_bytes = DEFAULT_MAX_VARIANT_BYTES)
    backlog_bytes > max_variant_bytes
  end

  # `R_ffmpeg`, read out of the published table rather than restated — so a
  # table that has drifted from the shipped ffmpeg fails the guard and moves the
  # matrix, rather than quietly under-predicting in both.
  #
  # Only the `+ norm` rows are dropped: they are the filtered case, and both
  # consumers want the plain figure as their base. (`norm` costs roughly 55 MiB
  # more per render, flat; the matrix says so in its caption.)
  def published_rss(path = CAPACITY_DOC)
    doc = File.read(path)
    table = doc[/<!-- rss-table:begin -->(.*?)<!-- rss-table:end -->/m, 1].to_s

    rows = table.lines.filter_map do |line|
      cells = line.split("|").map(&:strip)
      next unless cells.length >= 5

      label, rss = cells[1], cells[4]
      next if label.include?("norm") || label.include?("Variant") || label.start_with?("-")

      mibs = rss.gsub("*", "")[/([\d.]+)\s*MiB/, 1]
      next unless mibs

      # Rounded to whole bytes, and that is load-bearing rather than tidy. The
      # table publishes MiB to one decimal, so the obvious `Float(mibs) * MIB`
      # puts a Float into every term downstream — and then `RAM / per_render`,
      # which is exactly an integer when `RAM` came from the forward model,
      # comes back 15.999999999999998 and floors to 15. The inverse stopped
      # inverting, one slot at a time, in about a fifth of the published cells.
      # `bin/capacity-matrix --verify` is what found it. The model is bytes, and
      # bytes are integers.
      [label, (Float(mibs) * MIB).round]
    end

    raise "no usable rows in the #{path} table — run bin/measure-ffmpeg-rss" if rows.empty?

    rows.to_h
  end

  # The published figure for one format, worst case across the rows that measure
  # it. The table carries both a 60 s and a 2 h row for some formats (`mp3` and
  # `mp3 128k`), and the larger is the one to size from.
  def rss_for(format, table)
    matches = table.filter_map { |label, bytes| bytes if label.split(/\s+/).first == format }
    raise "no `#{format}` row in the published R_ffmpeg table" if matches.empty?

    matches.max
  end
end
