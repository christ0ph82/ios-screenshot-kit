# frozen_string_literal: true

require_relative "test_helper"
require "zlib"

class TestPngStrip < Minitest::Test
  include KitTestHelpers

  # Minimal type-2 PNG writer with per-row filter bytes, so the reader's
  # unfiltering is exercised against known pixels.
  def write_png(path, width:, height:, dark_rect: nil, filter: 0)
    rows = +"".b
    height.times do |y|
      rows << filter.chr
      row = +"".b
      width.times do |x|
        dark = dark_rect && y >= dark_rect[:y] && y < dark_rect[:y] + dark_rect[:h] &&
               x >= dark_rect[:x] && x < dark_rect[:x] + dark_rect[:w]
        value = dark ? 10 : 240
        row << [value, value, value].pack("C3")
      end
      # Filter type 2 (Up) needs encoding relative to the previous row; keep
      # the synthetic simple by only using filter 0 rows in the payload and a
      # separate explicit test for filtered content below.
      rows << row
    end
    chunk = lambda do |type, data|
      [data.bytesize].pack("N") + type.b + data.b + [Zlib.crc32(type.b + data.b)].pack("N")
    end
    File.binwrite(path, "\x89PNG\r\n\x1A\n".b +
      chunk.call("IHDR", [width, height, 8, 2, 0, 0, 0].pack("NNCCCCC")) +
      chunk.call("IDAT", Zlib::Deflate.deflate(rows)) +
      chunk.call("IEND", ""))
  end

  REGION = { x_range: 0.015..0.30, y_range: 0.025..0.055 }.freeze

  def test_clean_light_strip_measures_near_zero
    Dir.mktmpdir do |dir|
      path = File.join(dir, "clean.png")
      write_png(path, width: 400, height: 800)
      assert_in_delta 0.0, ScreenshotKit::PngStrip.dark_fraction(path, **REGION), 0.001
    end
  end

  def test_dark_block_in_breadcrumb_region_is_measured
    Dir.mktmpdir do |dir|
      path = File.join(dir, "crumb.png")
      # Dark block inside the region: x 20-80 of 400 (region spans x 6-120),
      # y 25-40 of 800 (region spans y 20-44).
      write_png(path, width: 400, height: 800, dark_rect: { x: 20, y: 25, w: 60, h: 15 })
      fraction = ScreenshotKit::PngStrip.dark_fraction(path, **REGION)
      assert_operator fraction, :>, 0.2
    end
  end

  def test_unsupported_png_returns_nil_not_clean
    Dir.mktmpdir do |dir|
      path = File.join(dir, "gray.png")
      # Grayscale (color type 0) is outside the reader's contract.
      chunk = lambda do |type, data|
        [data.bytesize].pack("N") + type.b + data.b + [Zlib.crc32(type.b + data.b)].pack("N")
      end
      rows = ("\x00" + "\xF0" * 8).b * 8
      File.binwrite(path, "\x89PNG\r\n\x1A\n".b +
        chunk.call("IHDR", [8, 8, 8, 0, 0, 0, 0].pack("NNCCCCC")) +
        chunk.call("IDAT", Zlib::Deflate.deflate(rows)) +
        chunk.call("IEND", ""))
      assert_nil ScreenshotKit::PngStrip.dark_fraction(path, **REGION)
    end
  end

  def test_real_capture_filters_decode
    # The kit's own placeholder writer uses filter-0 rows too, but real
    # XCUIScreen captures use adaptive filters; the calibration run against
    # live captures covered those. Here, prove a filter-1 (Sub) row decodes:
    # encoded bytes are deltas, so a constant row encodes as value,0,0,...
    Dir.mktmpdir do |dir|
      path = File.join(dir, "sub.png")
      width = 40
      rows = +"".b
      20.times do
        rows << "\x01".b # filter 1: Sub
        row = [240, 240, 240].pack("C3") + ([0, 0, 0].pack("C3") * (width - 1))
        rows << row
      end
      chunk = lambda do |type, data|
        [data.bytesize].pack("N") + type.b + data.b + [Zlib.crc32(type.b + data.b)].pack("N")
      end
      File.binwrite(path, "\x89PNG\r\n\x1A\n".b +
        chunk.call("IHDR", [width, 20, 8, 2, 0, 0, 0].pack("NNCCCCC")) +
        chunk.call("IDAT", Zlib::Deflate.deflate(rows)) +
        chunk.call("IEND", ""))
      fraction = ScreenshotKit::PngStrip.dark_fraction(path, x_range: 0.0..1.0, y_range: 0.0..0.9)
      assert_in_delta 0.0, fraction, 0.001, "Sub-filtered constant-light rows must decode light"
    end
  end
end

