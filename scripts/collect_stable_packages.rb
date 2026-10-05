#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'

module Solco
  module StablePackages
    def self.collect(input, destination, version, builder: nil)
      raise 'Expected a stable version' unless version.match?(/\A(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\z/)
      unless builder
        require 'native_packages'
        builder = NativePackages::Build.new(NativePackages::Configuration.new('native-packages.yaml'))
      end
      manifest = builder.verify(input, ids: %w[linux-amd64 linux-arm64])
      raise 'Native packages have the wrong version' unless manifest.fetch('version') == version
      files = manifest.fetch('packages').map { |entry| [File.join(input, entry.fetch('path')), entry.fetch('sha256')] }
      names = files.map { |path, _| File.basename(path) }
      raise 'Duplicate native package filenames' unless names.uniq == names
      files.each do |path, digest|
        output = File.join(destination, File.basename(path))
        File.open(output, 'wbx') { |file| IO.copy_stream(path, file) }
        raise 'Collected package checksum differs' unless Digest::SHA256.file(output).hexdigest == digest
      end
      files.length
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    raise 'Expected package directory, destination, and stable version' unless ARGV.length == 3
    count = Solco::StablePackages.collect(*ARGV)
    puts "Verified and collected #{count} stable Linux packages for #{ARGV.last}."
  rescue StandardError => error
    warn "Stable packages: #{error.message}"
    exit 1
  end
end
