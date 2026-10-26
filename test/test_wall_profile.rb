# frozen_string_literal: true

require_relative 'test_helper'

class WallProfileTest < Minitest::Test
  W = BIMSketch::WallProfile
  EPS = 0.001

  def test_plain_wall
    assert_equal [[0, 0], [500, 0], [500, 300], [0, 300]], W.outline(0, 500, 0, 300, [], EPS)
  end

  def test_door_notch
    out = W.outline(0, 500, 0, 300, [[205, 295, 0, 210]], EPS)
    assert_equal [[0, 0], [205, 0], [205, 210], [295, 210], [295, 0], [500, 0], [500, 300], [0, 300]], out
  end

  def test_door_at_wall_ends
    assert_equal [[0, 210], [90, 210], [90, 0], [500, 0], [500, 300], [0, 300]],
                 W.outline(0, 500, 0, 300, [[0, 90, 0, 210]], EPS)
    assert_equal [[0, 0], [410, 0], [410, 210], [500, 210], [500, 300], [0, 300]],
                 W.outline(0, 500, 0, 300, [[410, 500, 0, 210]], EPS)
  end

  def test_two_doors_sorted
    out = W.outline(0, 500, 0, 300, [[300, 380, 0, 200], [50, 130, 0, 210]], EPS)
    assert_equal [50, 0], out[1]
    assert_equal [300, 0], out[5]
  end

  def test_windows_are_holes
    ops = [[205, 295, 0, 210], [40, 160, 90, 230]]
    assert_equal [[[40, 90], [160, 90], [160, 230], [40, 230]]], W.holes(ops, 0, EPS)
    assert_equal 8, W.outline(0, 500, 0, 300, ops, EPS).size
  end

  def test_overlaps
    existing = [[205, 295, 0, 210]]
    assert W.overlaps?([250, 350, 90, 230], existing, 1)
    assert W.overlaps?([295, 395, 0, 210], existing, 1)
    refute W.overlaps?([40, 160, 90, 230], existing, 1)
  end

  def test_net_volume
    assert_in_delta 4.5 - 0.567, W.net_volume(0, 5, 0, 0.3, 0, 3, [[2.05, 2.95, 0, 2.1]]), 1e-9
  end

  def test_reveal_rects
    eps = 1e-6
    door = [1.0, 2.0, 0.0, 2.1]
    window = [3.0, 4.0, 0.9, 2.3]
    near = [4.02, 5.0, 1.0, 2.0] # 2 cm from the window
    out = BIMSketch::WallProfile.reveal_rects([door, window, near], 0.015, 0.0, 5.01, 0.0, 3.0, eps)
    assert_equal [0.985, 2.015, 0.0, 2.115], out[0].map { |v| v.round(6) }
    assert_in_delta 0.885, out[1][2], 1e-9          # sill lowered
    assert_in_delta 4.01 - eps, out[1][1], 1e-9     # stops halfway to the neighbour
    assert_in_delta 4.01 + eps, out[2][0], 1e-9
    assert_in_delta 5.01 - eps, out[2][1], 1e-9     # stops at the wall end
  end
end
