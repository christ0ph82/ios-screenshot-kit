# frozen_string_literal: true

require "zlib"

module ScreenshotKit
  # Decodes just the top strip of a PNG — enough rows to inspect the status
  # bar — with nothing but stdlib zlib. Exists for one reason: an App Store
  # capture can be photobombed by the iOS "back to previous app" breadcrumb
  # when some other process foregrounds a different app on the shared
  # simulator mid-run, and no hash comparison can see it. Reading pixels is
  # the only net.
  #
  # Handles the formats XCUIScreen screenshots actually use: 8-bit RGB (color
  # type 2) and RGBA (6), non-interlaced.
  module PngStrip
    module_function

    # Fraction of pixels darker than `threshold` (mean of RGB) inside the
    # fractional region x_range × y_range. Returns nil for a PNG this reader
    # does not handle — callers must treat nil as "cannot check", never as
    # "clean".
    def dark_fraction(path, x_range:, y_range:, threshold: 100)
      data = File.binread(path)
      return nil unless data[0, 8] == "\x89PNG\r\n\x1A\n".b

      width, height, bit_depth, color_type, interlace = data[16, 13].unpack("NNCCxxC")
      return nil unless bit_depth == 8 && [2, 6].include?(color_type) && interlace.zero?

      bytes_per_pixel = color_type == 2 ? 3 : 4
      row_bytes = 1 + width * bytes_per_pixel
      last_row = (height * y_range.end).floor
      needed = (last_row + 1) * row_bytes

      raw = inflate_prefix(data, needed)
      return nil if raw.nil? || raw.bytesize < needed

      rows = unfilter(raw, last_row + 1, row_bytes, bytes_per_pixel)

      x_start = (width * x_range.begin).floor
      x_end = (width * x_range.end).floor
      y_start = (height * y_range.begin).floor

      dark = 0
      total = 0
      (y_start..last_row).each do |y|
        row = rows[y]
        (x_start...x_end).each do |x|
          offset = x * bytes_per_pixel
          luminance = (row.getbyte(offset) + row.getbyte(offset + 1) + row.getbyte(offset + 2)) / 3
          dark += 1 if luminance < threshold
          total += 1
        end
      end
      return nil if total.zero?

      dark.to_f / total
    end

    # Inflates IDAT payloads only until `needed` bytes of raw scanline data
    # exist, so a 4 MB screenshot costs a few hundred KB of work.
    def inflate_prefix(data, needed)
      inflater = Zlib::Inflate.new
      output = +"".b
      position = 8
      while position + 8 <= data.bytesize
        length = data[position, 4].unpack1("N")
        type = data[position + 4, 4]
        if type == "IDAT"
          output << inflater.inflate(data[position + 8, length])
          break if output.bytesize >= needed
        elsif type == "IEND"
          break
        end
        position += 12 + length
      end
      output
    rescue Zlib::Error
      nil
    ensure
      inflater&.close rescue nil
    end

    # PNG row unfiltering (types 0-4) over the decoded prefix.
    def unfilter(raw, row_count, row_bytes, bytes_per_pixel)
      rows = []
      previous = "\x00".b * (row_bytes - 1)
      row_count.times do |index|
        line = raw[index * row_bytes, row_bytes]
        filter = line.getbyte(0)
        current = line[1..].b
        (0...current.bytesize).each do |i|
          left = i >= bytes_per_pixel ? current.getbyte(i - bytes_per_pixel) : 0
          up = previous.getbyte(i)
          up_left = i >= bytes_per_pixel ? previous.getbyte(i - bytes_per_pixel) : 0
          value = current.getbyte(i)
          decoded = case filter
                    when 0 then value
                    when 1 then value + left
                    when 2 then value + up
                    when 3 then value + ((left + up) / 2)
                    when 4 then value + paeth(left, up, up_left)
                    else value
                    end
          current.setbyte(i, decoded & 0xFF)
        end
        rows << current
        previous = current
      end
      rows
    end

    def paeth(left, up, up_left)
      estimate = left + up - up_left
      distance_left = (estimate - left).abs
      distance_up = (estimate - up).abs
      distance_up_left = (estimate - up_left).abs
      if distance_left <= distance_up && distance_left <= distance_up_left
        left
      elsif distance_up <= distance_up_left
        up
      else
        up_left
      end
    end
  end
end

