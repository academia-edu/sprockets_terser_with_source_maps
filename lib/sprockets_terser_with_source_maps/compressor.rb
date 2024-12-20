# frozen_string_literal: true

require 'sprockets/digest_utils'
require 'terser/compressor'
require 'logger'

module SprocketsTerserWithSourceMaps
  # Custom compressor to generate sourcemaps
  class Compressor < Terser::Compressor
    attr_accessor :logger

    def initialize(options = {})
      @logger = Logger.new($stdout)
      @logger.level = Logger::INFO
      @options = options.merge(Rails.application.config.assets.terser.to_h)
      super(@options)
    end

    def call(input)
      input_options = { source_map: { filename: input[:filename] } }

      data = input.fetch(:data)
      name = input.fetch(:name)

      if name.include? '-bundle'
        # Each webpack bundle already has a corresponding sourcemap, so let's use that
        sourcemap = JSON.parse(File.read("#{input[:filename]}.map"))
        sourcemap_json = sourcemap.to_json

        # Each webpack bundle is already minified, so let's only strip the existing
        # sourcemap reference; we'll replace it with a fingerprinted version below.
        compressed_js = data.sub(/\/\/# sourceMappingURL=.*$/, '').rstrip
      else
        compressed_js, map = @terser.compile_with_map(data, input_options)

        sourcemap = JSON.parse(map)

        if Rails.application.config.assets.sourcemaps_embed_source
          sourcemap['sourcesContent'] = [data]
        else
          # Generate uncompressed asset
          uncompressed_url = generate_asset_file(name, data, Rails.application.config.assets.uncompressed_prefix)

          sourcemap['sources'] = [uncompressed_url]
        end

        sourcemap['file'] = "#{name}.js"
        sourcemap_json = sourcemap.to_json
      end

      # Generate sourcemap file
      sourcemap_url = generate_asset_file(
        name, sourcemap_json,
        Rails.application.config.assets.sourcemaps_prefix,
        'js.map'
      )

      js = compressed_js.concat "\n//# sourceMappingURL=#{sourcemap_url}\n"

      { data: js, map: sourcemap }
    end

    private

    def generate_asset_file(name, data, prefix, extension = 'js')
      filename = File.join(Rails.application.config.assets.prefix, prefix, "#{name}-#{digest(data)}.#{extension}")
      file_path = File.join(Rails.public_path.to_s, filename)
      file_url = filename_to_url(filename)

      logger.info "Writing #{file_path}" if !File.exist?(file_path) && file_path.include?('.map')

      FileUtils.mkdir_p File.dirname(file_path)
      File.write(file_path, data)
      gzip_file(file_path) if gzip?

      file_url
    end

    def filename_to_url(filename)
      url_root = Rails.application.config.assets.sourcemaps_url_root
      case url_root
      when FalseClass
        filename
      when Proc
        url_root.call filename
      else
        File.join url_root.to_s, filename
      end
    end

    def gzip?
      config = Rails.application.config.assets
      config.sourcemaps_gzip || (config.sourcemaps_gzip.nil? && config.gzip)
    end

    def gzip_file(path)
      logger.info "Writing #{path}.gz" if !File.exist?("#{path}.gz") && path.include?('.map')

      Zlib::GzipWriter.open("#{path}.gz") do |gz|
        gz.mtime = File.mtime(path)
        gz.orig_name = path
        gz.write File.binread(path)
      end
    end

    def digest(io)
      Sprockets::DigestUtils.pack_hexdigest Sprockets::DigestUtils.digest(io)
    end
  end
end
