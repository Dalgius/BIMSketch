# frozen_string_literal: true

require_relative 'test_helper'

class OpeningTypesTest < Minitest::Test
  O = BIMSketch::OpeningTypes

  def test_catalogue
    assert_equal %w[D1 D2 D3 D4], O.all('door').map { |t| t['id'] }
    assert_equal %w[W1 W2 W3 W4], O.all('window').map { |t| t['id'] }
    assert_equal O.all.size, O.all.map { |t| t['id'] }.uniq.size
    O.all.each do |t|
      assert t['width'].positive? && t['height'].positive?, t['id']
      assert_equal 0.0, t['sill'], t['id'] if t['kind'] == 'door'
    end
  end

  def test_for_kind_falls_back_to_default
    assert_equal 'D2', O.for_kind('door', 'D2')['id']
    assert_equal 'D1', O.for_kind('door', 'W1')['id']
    assert_equal 'W2', O.for_kind('window', nil)['id']
  end

  def test_leaf_spans
    spans = O.leaf_spans(1.0, 2, 0.02)
    assert_equal 2, spans.size
    assert_in_delta 0.49, spans[0][1], 1e-12
    assert_in_delta 0.51, spans[1][0], 1e-12
    assert_in_delta 1.0, spans[1][1], 1e-12
    assert_equal [[0.0, 1.0]], O.leaf_spans(1.0, 0)
  end

  def test_position
    assert_equal 'inner', O.position(O.find('W2'))
    assert_equal 'center', O.position(O.find('D1'))
    assert_equal 'outer', O.position(O.find('W2'), 'outer')
    assert_equal 'inner', O.position(O.find('W2'), 'boh')
  end

  # Wall 0.40 thick, frame 0.08 deep, finishes 0.01 (y = 0) and 0.015 (y = t).
  def test_frame_offset
    assert_in_delta 0.16, O.frame_offset(0.4, 0.08, 'center'), 1e-12
    assert_in_delta 0.305, O.frame_offset(0.4, 0.08, 'inner', r_lo: 0.01, r_hi: 0.015), 1e-12
    assert_in_delta 0.01, O.frame_offset(0.4, 0.08, 'outer', r_lo: 0.01, r_hi: 0.015), 1e-12
    # Flipped wall: the interior face is at y = 0.
    assert_in_delta 0.01, O.frame_offset(0.4, 0.08, 'inner', interior_hi: false, r_lo: 0.01, r_hi: 0.015), 1e-12
    # A frame deeper than the wall stays inside it.
    assert_in_delta 0.0, O.frame_offset(0.05, 0.08, 'inner'), 1e-12
  end
end
