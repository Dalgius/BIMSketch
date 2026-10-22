# frozen_string_literal: true

require_relative 'test_helper'

class WallJointTest < Minitest::Test
  J = BIMSketch::WallJoint
  T = 0.3

  # World footprint (4 corners) of each wall of a chain.
  def quads(points, align, closed)
    lo, hi = J.band(align, T)
    exts = J.chain(points, lo, hi, closed: closed)
    segs = points.each_cons(2).to_a
    segs << [points.last, points.first] if closed
    segs.each_with_index.map do |(p, q), i|
      d = J.direction(p, q)
      n = [-d[1], d[0]]
      len = Math.hypot(q[0] - p[0], q[1] - p[1])
      J.footprint(len, hi - lo, exts[i]).map do |x, y|
        off = lo + y
        [p[0] + x * d[0] + off * n[0], p[1] + x * d[1] + off * n[1]]
      end
    end
  end

  def assert_point(a, b, msg = nil)
    assert_in_delta a[0], b[0], 1e-9, msg
    assert_in_delta a[1], b[1], 1e-9, msg
  end

  # Consecutive walls share their mitre edge: no gap, no overlap.
  def assert_mitred(qs, closed)
    pairs = (0...qs.size - 1).map { |i| [i, i + 1] }
    pairs << [qs.size - 1, 0] if closed
    pairs.each do |i, j|
      assert_point qs[i][1], qs[j][0], "lo edge #{i}->#{j}"
      assert_point qs[i][2], qs[j][3], "hi edge #{i}->#{j}"
    end
  end

  RECT_CCW = [[0, 0], [5, 0], [5, 4], [0, 4]].freeze

  def test_closed_rectangles_all_alignments
    { 'center' => 5.3 * 4.3 - 4.7 * 3.7 }.merge(
      'left' => 5 * 4 - 4.4 * 3.4, 'right' => 5.6 * 4.6 - 5 * 4
    ).each do |align, area|
      qs = quads(RECT_CCW, align, true)
      assert_mitred(qs, true)
      assert_in_delta area, qs.sum { |q| J.area(q) }, 1e-9, align
    end
    qs = quads(RECT_CCW.reverse, 'left', true)
    assert_mitred(qs, true)
    assert_in_delta 5.6 * 4.6 - 5 * 4, qs.sum { |q| J.area(q) }, 1e-9
  end

  # The perimeter drawn by the user in SketchUp: no right angles.
  def test_irregular_quadrilateral
    pts = [[0, 0], [0, 3.799], [2.941, 3.263], [2.390, -1.443]]
    %w[left center right].each do |align|
      qs = quads(pts, align, true)
      assert_mitred(qs, true)
      outer = qs.map { |q| q[0] }
      inner = qs.map { |q| q[3] }
      assert_in_delta (J.area(outer) - J.area(inner)).abs, qs.sum { |q| J.area(q) }, 1e-9, align
    end
  end

  def test_open_l_shape
    qs = quads([[0, 0], [4, 0], [4, 3]], 'center', false)
    assert_mitred(qs, false)
    assert_point [4.15, -0.15], qs[0][1]
    assert_point [3.85, 0.15], qs[0][2]
    assert_point [0, -0.15], qs[0][0]
  end

  def test_reversed_wall
    band = J.band('left', T)
    # A drawn from the corner towards -x, seen reversed (+x, flipped band),
    # B drawn from the corner towards -y.
    ends, starts = J.corner([1, 0], [0, -1], J.flip(band), band)
    assert_in_delta 0.0, ends[0], 1e-9
    assert_in_delta T, ends[1], 1e-9
    assert_in_delta(-T, starts[0], 1e-9)
    assert_in_delta 0.0, starts[1], 1e-9
  end

  def test_no_joint_when_collinear_or_too_acute
    b = [-0.15, 0.15]
    assert_nil J.corner([1, 0], [1, 0], b, b)
    a = 0.03
    assert_nil J.corner([1, 0], [-Math.cos(a), Math.sin(a)], b, b)
  end

  def test_core_range_and_ext_formats
    assert_equal [0.0, 0.0, 0.5, 0.5], J.normalize_ext([0, 0.5])
    assert_equal [0.15, 4.85], J.core_range(5.0, [0.15, -0.15, 0.15, -0.15]).map { |v| v.round(9) }
    assert_equal [1, 2, 3, 4], J.flip_ext([4, 3, 2, 1])
  end
end
