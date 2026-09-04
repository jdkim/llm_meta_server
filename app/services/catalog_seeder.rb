# frozen_string_literal: true

# Loads config/llm_models.yml into the database.
#
# Used once to move the catalog out of the file, and re-runnable afterwards to
# reset to the checked-in defaults. Idempotent: matches on (llm.family, name)
# and updates in place, so favourites and anything else referencing a meta_id
# keep working.
#
# The YAML's comments are the reason this is not a two-line loader. They record
# why entries look the way they do — that qwen ignores the /no_think directive,
# that Haiku rejects adaptive thinking, that gpt-5.5-pro is Responses-only —
# and a plain YAML.load drops them on the floor. They are extracted here into
# each model's `notes` so the knowledge survives the move.
class CatalogSeeder
  CATALOG_PATH = Rails.root.join("config", "llm_models.yml")

  # The checked-in catalog, unless an environment overrides it. Only the test
  # environment does: the suite pins a stable catalog of its own so that
  # curating production models does not break specs that name one.
  def self.catalog_path
    Rails.configuration.x.catalog_path.presence || CATALOG_PATH
  end

  def self.call(path: catalog_path, prune: false)
    raw   = YAML.safe_load_file(path, permitted_classes: [ Symbol, Date ])
    notes = extract_notes(File.read(path))
    stats = { created: 0, updated: 0, pruned: 0 }

    raw.each do |family, models|
      llm = Llm.find_or_create_by!(family: family) { |l| l.name = family.capitalize }
      seen = []

      models.each_with_index do |(meta_id, attrs), index|
        seen << meta_id
        record = LlmModel.find_or_initialize_by(llm: llm, name: meta_id)
        was_new = record.new_record?

        record.assign_attributes(
          api_id: attrs["api_id"],
          display_name: attrs["display_name"],
          supports_vision: attrs["supports_vision"] == true,
          supports_tools: attrs["supports_tools"] == true,
          responses_only: attrs["responses_only"] == true,
          kind: attrs["kind"].presence,
          endpoint: attrs["endpoint"].presence,
          defaults: attrs["defaults"] || {},
          pricing: stringify_dates(attrs["pricing"] || {}),
          notes: notes[[ family, meta_id ]],
          position: index,
          active: true
        )
        record.save!
        was_new ? stats[:created] += 1 : stats[:updated] += 1
      end

      if prune
        stale = llm.llm_models.where.not(name: seen)
        stats[:pruned] += stale.count
        stale.destroy_all
      end
    end

    stats
  end

  # reviewed_at parses as a Date; jsonb wants it as a string so it round-trips.
  def self.stringify_dates(hash)
    hash.transform_values { |v| v.is_a?(Date) ? v.iso8601 : v }
  end

  # Associates each model key with the comment lines that document it: the
  # contiguous comment block immediately above it, plus any comments inside
  # its own block. Returns { [family, meta_id] => "text" }.
  def self.extract_notes(text)
    notes   = {}
    family  = nil
    lines   = text.lines
    pending = []

    lines.each_with_index do |line, i|
      case line
      when /\A(\S+):\s*\z/          # provider key
        family  = Regexp.last_match(1)
        pending = []
      when /\A\s*#\s?(.*)$/         # a comment line
        pending << Regexp.last_match(1).rstrip
      when /\A  (\S+):\s*\z/        # model key
        meta_id = Regexp.last_match(1)
        body    = pending.dup
        pending = []
        body.concat(inner_comments(lines, i))
        notes[[ family, meta_id ]] = body.join("\n").strip.presence
      when /\A\s*\z/
        # blank line ends a floating comment block
        pending = []
      else
        pending = []
      end
    end
    notes
  end

  # Comment lines inside a model's own block (up to the next model/provider).
  def self.inner_comments(lines, start)
    out = []
    ((start + 1)...lines.size).each do |i|
      break if lines[i] =~ /\A\S/ || lines[i] =~ /\A  \S/
      out << Regexp.last_match(1).rstrip if lines[i] =~ /\A\s*#\s?(.*)$/
    end
    out
  end
end
