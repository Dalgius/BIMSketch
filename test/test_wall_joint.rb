# frozen_string_literal: true

require_relative 'test_helper'

class WallJointTest < Minitest::Test
  J = BIMSketch::WallJoint
  T = 0.3

  # Footprint (axis-aligned box [xmin, xmax, ymin, ymax]) of each wall of a chain.
  def footprints(points, align, closed)
    lo, hi = J.band(align, T)
    exts = J.chain(points, lo, hi, closed: closed)
    segs = points.each_cons(2).to_a
    segs << [points.last, points.first] if closed
    segs.each_with_index.map do |(p, q), i|
      d = J.direction(p, q)
      n = [-d[1], d[0]]
      len = Math.hypot(q[0] - p[0], q[1] - p[1])
      s0 = -exts[i][0]
      s1 = len + exts[i][1]
      corners = [[s0, lo], [s1, lo], [s1, hi], [s0, hi]].map do |s, u|
        [p[0] + s * d[0] + u * n[0], p[1] + s * d[1] + u * n[1]]
      end
      xs = corners.map(&:first)
      ys = corners.map(&:last)
      [xs.min, xs.max, ys.min, ys.max]
    end
  end

  def area(b)
    (b[1] - b[0]) * (b[3] - b[2])
  end

  def overlap(a, b)
    w = [a[1], b[1]].min - [a[0], b[0]].max
    h = [a[3], b[3]].min - [a[2], b[2]].max
    w > 1e-9 && h > 1e-9 ? w * h : 0.0
  end

  def assert_clean_ring(points, align, expected_area)
    boxes = footprints(points, align, true)
    boxes.combination(2).each { |a, b| assert_in_delta 0.0, overlap(a, b), 1e-9, "#{align}: overlap" }
    assert_in_delta expected_area, boxes.sum { |b| area(b) }, 1e-9, "#{align}: area"
  end

  RECT_CCW = [[0, 0], [5, 0], [5, 4], [0, 4]].freeze

  def test_closed_rectangle_centered
    # Outer 5.3 x 4.3 minus inner 4.7 x 3.7.
    [RECT_CCW, RECT_CCW.reverse].each { |pts| assert_clean_ring(pts, 'center', 5.3 * 4.3 - 4.7 * 3.7) }
  end

  def test_closed_rectangle_left_and_right
    inside = 5 * 4 - 4.4 * 3.4
    outside = 5.6 * 4.6 - 5 * 4
    assert_clean_ring(RECT_CCW, 'left', inside)
    assert_clean_ring(RECT_CCW, 'right', outside)
    assert_clean_ring(RECT_CCW.reverse, 'left', outside)
    assert_clean_ring(RECT_CCW.reverse, 'right', inside)
  end

  def test_open_l_shape_centered
    boxes = footprints([[0, 0], [4, 0], [4, 3]], 'center', false)
    assert_in_delta 0.0, overlap(boxes[0], boxes[1]), 1e-9
    assert_in_delta 4.15, boxes[0][1], 1e-9
    assert_in_delta 0.15, boxes[1][2], 1e-9
  end

  # Walls joined at their start points: the first one is seen reversed.
  def test_reversed_wall_uses_flipped_band
    band = J.band('left', T)
    # A drawn from the corner towards -x occupies y in [-t, 0]; B drawn from the
    # corner towards +y occupies x in [-t, 0]: they already meet without overlap.
    assert_equal [0.0, 0.0], J.corner([1, 0], [0, 1], J.flip(band), band).map { |v| v.round(9).abs }
    # Same corner with B going -y (x in [0, t]): A must reach x = t, B starts at y = -t.
    s, r = J.corner([1, 0], [0, -1], J.flip(band), band)
    assert_in_delta 0.3, s, 1e-9
    assert_in_delta 0.3, r, 1e-9
  end

  def test_collinear_has_no_joint
    assert_equal [0.0, 0.0], J.corner([1, 0], [1, 0], [-0.15, 0.15], [-0.15, 0.15])
  end
end
