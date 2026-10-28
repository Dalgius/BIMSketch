# frozen_string_literal: true

require_relative 'test_helper'

class WallLoopTest < Minitest::Test
  L = BIMSketch::WallLoop
  P = BIMSketch::Polygon

  def wall(a, b, t = 0.3)
    { a: a, b: b, band: [-t / 2, t / 2] }
  end

  def rect_walls
    [wall([0, 0], [5, 0]), wall([5, 0], [5, 4]), wall([5, 4], [0, 4]), wall([0, 4], [0, 0])]
  end

  def bounds(poly)
    xs = poly.map(&:first)
    ys = poly.map(&:last)
    [xs.min, xs.max, ys.min, ys.max].map { |v| v.round(9) }
  end

  def test_outer_inner_axis
    assert_equal [-0.15, 5.15, -0.15, 4.15], bounds(L.outline(rect_walls))
    assert_equal [0.15, 4.85, 0.15, 3.85], bounds(L.outline(rect_walls, side: :inner))
    assert_equal [0.0, 5.0, 0.0, 4.0], bounds(L.outline(rect_walls, side: :axis))
    assert_in_delta 5.3 * 4.3, P.signed_area(L.outline(rect_walls)), 1e-9
  end

  # Clockwise drawing, walls reversed and shuffled: same outline.
  def test_any_order_and_direction
    w = [wall([0, 0], [0, 4]), wall([5, 4], [5, 0]), wall([0, 4], [5, 4]), wall([0, 0], [5, 0])]
    assert_equal [-0.15, 5.15, -0.15, 4.15], bounds(L.outline(w))
    # Wall drawn with 'left' alignment: band [0, t] on the left of its direction.
    w2 = rect_walls
    w2[0] = { a: [0, 0], b: [5, 0], band: [0.0, 0.3] }
    assert_in_delta 0.0, bounds(L.outline(w2))[2], 1e-9
  end

  def test_non_rectangular_and_collinear
    w = [wall([0, 0], [3, 0]), wall([3, 0], [6, 0]), wall([6, 0], [4, 4]), wall([4, 4], [0, 4]), wall([0, 4], [0, 0])]
    poly = L.outline(w)
    assert_equal 4, poly.size # the collinear vertex at (3, 0) disappears
    assert P.signed_area(poly).positive?
  end

  def test_open_or_branched_chain
    assert_nil L.outline(rect_walls.first(3))
    assert_nil L.outline(rect_walls + [wall([5, 0], [8, 0])])
  end

  def test_polygon_inside_overlap
    outer = [[0, 0], [5, 0], [5, 4], [0, 4]]
    assert P.inside?(P.rect([1, 1], [2, 3]), outer)
    refute P.inside?(P.rect([4, 1], [6, 3]), outer)
    assert P.overlap?(P.rect([1, 1], [2, 2]), P.rect([1.5, 1.5], [3, 3]))
    refute P.overlap?(P.rect([1, 1], [2, 2]), P.rect([2.5, 1], [3, 2]))
  end
end

class StairCalcTest < Minitest::Test
  S = BIMSketch::StairCalc

  def test_blondel
    c = S.compute(3.0)
    assert_equal 18, c[:risers]
    assert_in_delta 3.0 / 18, c[:riser], 1e-12
    assert_in_delta 0.63 - 2 * 3.0 / 18, c[:tread], 1e-12
    assert_equal 17, c[:treads]
    assert_in_delta 17 * c[:tread], c[:run], 1e-12
  end

  def test_profile_reaches_floor_and_top
    c = S.compute(3.0)
    pts = S.profile(c)
    assert_in_delta 3.0, pts.map(&:last).max, 1e-9
    assert_in_delta c[:run], pts.map(&:first).max, 1e-9
    assert_equal [0.0, 0.0], pts.first
    assert BIMSketch::Polygon.signed_area(pts).abs.positive?
  end
end
