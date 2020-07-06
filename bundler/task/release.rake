# frozen_string_literal: true

require_relative "../lib/bundler/gem_tasks"

Bundler::GemHelper.tag_prefix = "bundler-"

task :build_metadata do
  build_metadata = {
    :built_at => Bundler::GemHelper.gemspec.date.utc.strftime("%Y-%m-%d"),
    :git_commit_sha => `git rev-parse --short HEAD`.strip,
    :release => Rake::Task["release"].instance_variable_get(:@already_invoked),
  }

  Spec::Path.replace_build_metadata(build_metadata)
end

namespace :build_metadata do
  task :clean do
    build_metadata = {
      :release => false,
    }

    Spec::Path.replace_build_metadata(build_metadata)
  end
end

task :build => ["build_metadata"] do
  Rake::Task["build_metadata:clean"].tap(&:reenable).real_invoke
end
task "release:rubygem_push" => ["release:verify_docs", "release:verify_github", "build_metadata", "release:github"]

namespace :release do
  task :verify_docs => :"man:check"

  def gh_api_post(opts)
    require "netrc"
    require "net/http"
    require "json"
    _username, token = Netrc.read["api.github.com"]

    host = opts.fetch(:host) { "https://api.github.com/" }
    path = opts.fetch(:path)
    uri = URI.join(host, path)
    uri.query = [uri.query, "access_token=#{token}"].compact.join("&")
    headers = {
      "Content-Type" => "application/json",
      "Accept" => "application/vnd.github.v3+json",
      "Authorization" => "token #{token}",
    }.merge(opts.fetch(:headers, {}))
    body = opts.fetch(:body) { nil }

    response = if body
      Net::HTTP.post(uri, body.to_json, headers)
    else
      Net::HTTP.get_response(uri)
    end

    if response.code.to_i >= 400
      raise "#{uri}\n#{response.inspect}\n#{begin
                                              JSON.parse(response.body)
                                            rescue JSON::ParseError
                                              response.body
                                            end}"
    end
    JSON.parse(response.body)
  end

  task :verify_github do
    require "pp"
    gh_api_post :path => "/user"
  end

  def gh_api_request(opts)
    require "net/http"
    require "json"
    host = opts.fetch(:host) { "https://api.github.com/" }
    path = opts.fetch(:path)
    response = Net::HTTP.get_response(URI.join(host, path))

    links = Hash[*(response["Link"] || "").split(", ").map do |link|
      href, name = link.match(/<(.*?)>; rel="(\w+)"/).captures

      [name.to_sym, href]
    end.flatten]

    parsed_response = JSON.parse(response.body)

    if n = links[:next]
      parsed_response.concat gh_api_request(:host => host, :path => n)
    end

    parsed_response
  end

  desc "Push the release to Github releases"
  task :github do
    def release_notes(version)
      title_token = "## "
      current_version_title = "#{title_token}#{version}"
      current_minor_title = "#{title_token}#{version.segments[0, 2].join(".")}"
      text = File.open("CHANGELOG.md", "r:UTF-8", &:read)
      lines = text.split("\n")

      current_version_index = lines.find_index {|line| line.strip =~ /^#{current_version_title}($|\b)/ }
      unless current_version_index
        raise "Update the changelog for the last version (#{version})"
      end
      current_version_index += 1
      previous_version_lines = lines[current_version_index.succ...-1]
      previous_version_index = current_version_index + (
        previous_version_lines.find_index {|line| line.start_with?(title_token) && !line.start_with?(current_minor_title) } ||
        lines.count
      )

      relevant = lines[current_version_index..previous_version_index]

      relevant.join("\n").strip
    end

    version = Gem::Version.new(Bundler::GemHelper.gemspec.version)
    tag = "bundler-v#{version}"

    gh_api_post :path => "/repos/rubygems/rubygems/releases",
                :body => {
                  :tag_name => tag,
                  :name => tag,
                  :body => release_notes(version),
                  :prerelease => version.prerelease?,
                }
  end

  desc "Replace the unreleased section in the changelog with new content. Pass the new content through ENV['NEW_CHANGELOG_CONTENT']"
  task :write_changelog do
    section_token = "## "
    unreleased_section_title = "#{section_token}(Unreleased)"
    changelog_content = File.open("CHANGELOG.md", "r:UTF-8", &:read).split("\n")

    current_rest_of_content = changelog_content.drop_while {|line| line.start_with?(unreleased_section_title) || !line.start_with?(section_token) }
    new_content = ENV["NEW_CHANGELOG_CONTENT"]

    File.open("CHANGELOG.md", "w:UTF-8") {|f| f.write([new_content, current_rest_of_content].join("\n") + "\n") } if new_content
  end

  desc "Prepare a patch release with the PRs from master in the patch milestone"
  task :prepare_patch, :version do |_t, args|
    version = args.version
    current_version = Bundler::GemHelper.gemspec.version

    version ||= begin
      segments = current_version.segments
      if segments.last.is_a?(String)
        segments << "1"
      else
        segments[-1] += 1
      end
      segments.join(".")
    end

    puts "Cherry-picking PRs milestoned for #{version} (currently #{current_version}) into the stable branch..."

    milestones = gh_api_request(:path => "repos/rubygems/rubygems/milestones?state=open")
    unless patch_milestone = milestones.find {|m| m["title"] == version }
      abort "failed to find #{version} milestone on GitHub"
    end
    prs = gh_api_request(:path => "repos/rubygems/rubygems/issues?milestone=#{patch_milestone["number"]}&state=all")
    prs.map! do |pr|
      abort "#{pr["html_url"]} hasn't been closed yet!" unless pr["state"] == "closed"
      next unless pr["pull_request"]
      pr["number"].to_s
    end
    prs.compact!

    branch = Gem::Version.new(version).segments.map.with_index {|s, i| i == 0 ? s + 1 : s }[0, 2].join(".")
    sh("git", "checkout", "-b", "release_bundler/#{version}", branch)

    commits = `git log --oneline origin/master -- bundler`.split("\n").map {|l| l.split(/\s/, 2) }.reverse
    commits.select! {|_sha, message| message =~ /(Auto merge of|Merge pull request|Merge) ##{Regexp.union(*prs)}/ }

    abort "Could not find commits for all PRs" unless commits.size == prs.size

    if commits.any? && !system("git", "cherry-pick", "-x", "-m", "1", *commits.map(&:first))
      warn "Opening a new shell to fix the cherry-pick errors. Press Ctrl-D when done to resume the task"

      unless system(ENV["SHELL"] || "zsh")
        abort "Failed to resolve conflicts on a different shell. Resolve conflicts manually and finish the task manually"
      end
    end

    version_file = "lib/bundler/version.rb"
    version_contents = File.read(version_file)
    unless version_contents.sub!(/^(\s*VERSION = )"#{Gem::Version::VERSION_PATTERN}"/, "\\1#{version.to_s.dump}")
      abort "failed to update #{version_file}, is it in the expected format?"
    end
    File.open(version_file, "w") {|f| f.write(version_contents) }

    sh("git", "commit", "-am", "Version #{version}")
  end
end
