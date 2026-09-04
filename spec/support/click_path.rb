# frozen_string_literal: true

# Helpers for exercising a real click-path: follow the links the page actually
# renders, and submit the values the form actually offers.
#
# Written after three bugs that hand-written request params could not catch,
# because each was a handoff failure — one step produced something the next
# step rejected:
#
#   * the Add form pre-filled per_image pricing but left `kind` blank, so
#     validation demanded input/output and refused its own offering
#   * the candidate list kept advertising models already added
#   * the drift panel kept listing prices already corrected
#
# Hand-written params sail past all three. Submitting what the page renders
# does not.
module ClickPath
  def page = Nokogiri::HTML(response.body)

  # The href of the first rendered link whose text matches, optionally scoped
  # to a container. Scoping matters: the layout header carries its own
  # "Models" link to the public page, so matching on text alone can walk you
  # straight out of the admin area.
  def link_href(pattern, within: nil)
    scope = within ? page.css(within) : page
    node  = scope.css("a").find { |a| a.text.strip.match?(pattern) }
    raise "no link matching #{pattern.inspect}#{" within #{within}" if within} on the page" if node.nil?
    node["href"]
  end

  def click_link(pattern, within: nil)
    get link_href(pattern, within: within)
  end

  # Follow a link in the admin section nav specifically.
  def click_nav(label)
    click_link(/\A#{Regexp.escape(label)}\z/, within: "[data-admin-nav]")
  end

  # The rendered <form> containing a given field name, read the way a browser
  # would submit it — so the request carries the page's own values, not ours.
  def rendered_form(containing:)
    form = page.css("form").find { |f| f.css("[name]").any? { |n| n["name"].to_s.include?(containing) } }
    raise "no form containing a #{containing.inspect} field" if form.nil?

    params = {}
    form.css("input, textarea, select").each do |node|
      name = node["name"].to_s
      next if name.empty? || name == "authenticity_token" || node["type"] == "submit"

      value =
        case node.name
        when "textarea" then node.text
        when "select"
          opt = node.css("option[selected]").first || node.css("option").first
          opt&.[]("value").to_s
        else
          # An unchecked checkbox contributes only its hidden "0" partner.
          next if node["type"] == "checkbox" && node["checked"].nil?
          node["value"].to_s
        end
      params[name] = value
    end

    method = form.css("input[name=_method]").first&.[]("value") || form["method"] || "post"
    { action: form["action"], method: method.downcase, params: params }
  end

  # Submit a rendered form verbatim.
  def submit_rendered_form(containing:)
    f = rendered_form(containing: containing)
    query  = f[:params].map { |k, v| "#{CGI.escape(k)}=#{CGI.escape(v)}" }.join("&")
    nested = Rack::Utils.parse_nested_query(query)
    send(f[:method] == "patch" ? :patch : :post, f[:action], params: nested)
  end
end
