# frozen_string_literal: true

require_relative 'test_helper'

class WallTypesTest < Minitest::Test
  W = BIMSketch::WallTypes
  J = BIMSketch::WallJoint

  def lib
    W.default_library
  end

  def test_thickness_and_summary
    t = W.find(lib, 'WT1')
    assert_in_delta 0.425, W.thickness(t), 1e-9
    assert_equal '1 + 10 + 30 + 1,5 cm', W.summary(t)
  end

  def test_u_value_iso_6946
    t = W.find(lib, 'WT1')
    r = 0.01 / 0.9 + 0.10 / 0.031 + 0.30 / 0.20 + 0.015 / 0.70
    assert_in_delta 1.0 / (r + 0.13 + 0.04), W.u_value(t), 1e-9
    assert_in_delta 1.0 / (r + 0.26), W.u_value(t, external: false), 1e-9
    t['layers'][1]['lambda'] = nil
    assert_nil W.u_value(t)
  end

  def test_normalize
    out = W.normalize([
      { 'id' => 'A', 'name' => '', 'layers' => [{ 'material' => 'Cls', 'thickness' => '0,2', 'lambda' => '2,3',
                                                  'function' => 'structure' },
                                                { 'material' => 'x', 'thickness' => '0' }] },
      { 'id' => 'A', 'name' => 'Doppio', 'layers' => [{ 'name' => 'Isolante', 'thickness' => 0.05 }] },
      { 'id' => 'B', 'name' => 'Vuoto', 'layers' => [] }
    ])
    assert_equal 2, out.size
    assert_equal 1, out[0]['layers'].size
    assert_in_delta 2.3, out[0]['layers'][0]['lambda']
    assert_equal 'Cls', out[0]['layers'][0]['name']
    refute_equal out[0]['id'], out[1]['id']
    assert_equal 'other', out[1]['layers'][0]['function']
    assert_equal 'Isolante', out[1]['layers'][0]['material']
  end

  def test_bands_scaled_and_flipped
    t = W.find(lib, 'WT2')
    b = W.bands(t, 33.0)
    assert_equal 3, b.size
    assert_in_delta 0.0, b[0][0]
    assert_in_delta 33.0, b[-1][1], 1e-9
    assert_in_delta 1.5, b[0][1], 1e-9
    f = W.bands(t, 33.0, flipped: true)
    assert_equal [2, 1, 0], f.map(&:last)
  end

  # The layers of a mitred wall tile the wall footprint exactly.
  def test_band_ext_tiles_footprint
    ext = [0.2, -0.1, 0.3, -0.25]
    total = J.area(J.footprint(5.0, 0.4, ext))
    parts = [[0.0, 0.1], [0.1, 0.35], [0.35, 0.4]].sum do |y0, y1|
      J.area(J.footprint(5.0, y1 - y0, J.band_ext(ext, 0.4, y0, y1)))
    end
    assert_in_delta total, parts, 1e-12
    assert_equal ext.map { |v| v.round(12) }, J.band_ext(ext, 0.4, 0.0, 0.4).values_at(0, 1, 2, 3).map { |v| v.round(12) }
  end
end
