# frozen_string_literal: true

require_relative "path"

module Spec
  module BuildMetadata
    include Spec::Path

    def replace_build_metadata(build_metadata, dir: source_root)
      build_metadata_file = File.expand_path("lib/bundler/build_metadata.rb", dir)

      ivars = build_metadata.sort.map do |k, v|
        "    @#{k} = #{loaded_gemspec.send(:ruby_code, v)}"
      end.join("\n")

      contents = File.read(build_metadata_file)
      contents.sub!(/^(\s+# begin ivars).+(^\s+# end ivars)/m, "\\1\n#{ivars}\n\\2")
      File.open(build_metadata_file, "w") {|f| f << contents }
    end

  private

    extend self
  end
end
