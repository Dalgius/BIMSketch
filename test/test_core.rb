# frozen_string_literal: true

require_relative 'test_helper'

class GuidTest < Minitest::Test
  G = BIMSketch::Guid

  def test_generate_is_valid_and_unique
    a = Array.new(200) { G.generate }
    assert(a.all? { |g| G.valid?(g) })
    assert_equal a.size, a.uniq.size
  end

  def test_roundtrip
    hex = '0f1e2d3c4b5a69788796a5b4c3d2e1f0'
    assert_equal hex, G.expand(G.compress(hex))
    assert_equal '0000000000000000000000', G.compress('0' * 32)
    assert_equal '3$$$$$$$$$$$$$$$$$$$$$', G.compress('f' * 32)
  end

  def test_seed_is_deterministic
    assert_equal G.from_seed('abc'), G.from_seed('abc')
    refute_equal G.from_seed('abc'), G.from_seed('abd')
  end

  def test_invalid
    refute G.valid?('abc')
    refute G.valid?('4' + '0' * 21)
    refute G.valid?(nil)
  end
end

class StepTest < Minitest::Test
  S = BIMSketch::Step

  def test_strings
    assert_equal "'abc'", S.str('abc')
    assert_equal "'l''uomo'", S.str("l'uomo")
    assert_equal "'a\\\\b'", S.str('a\\b')
    assert_equal "'Citt\\X2\\00E0\\X0\\'", S.str('Città')
    assert_equal "'\\X2\\00B2\\X0\\ m'", S.str('² m')
    assert_equal '$', S.str(nil)
  end

  def test_reals
    assert_equal '0.', S.real(0)
    assert_equal '1.5', S.real(1.5)
    assert_equal '-2.', S.real(-2)
    assert_equal '0.', S.real(-0.0000000001)
    assert_equal '0.123457', S.real(0.1234567)
  end
end

class ElementTypesTest < Minitest::Test
  T = BIMSketch::ElementTypes

  def test_catalog
    assert_equal 'IfcWall', T['wall'].ifc_class
    assert_equal T.keys.size, T.keys.uniq.size
    T.all.each do |t|
      assert t.predefined.include?('NOTDEFINED'), t.key
      t.quantities.each { |q| assert_includes %i[length area volume], q.kind }
    end
  end

  def test_coerce
    assert_equal true, T.coerce(:boolean, 'true')
    assert_equal false, T.coerce(:boolean, 'no')
    assert_in_delta 0.28, T.coerce(:thermal, '0,28')
    assert_nil T.coerce(:real, 'abc')
    assert_nil T.coerce(:label, '  ')
    assert_equal 12, T.coerce(:count, '12')
  end
end

class QuantitiesTest < Minitest::Test
  Q = BIMSketch::Quantities

  def test_wall_quantities
    q = Q.for_type('wall', Fixtures.box_measures(5.0, 0.3, 3.0))
    assert_in_delta 5.0, Q.value(q, 'Length')
    assert_in_delta 15.0, Q.value(q, 'GrossSideArea')
    assert_in_delta 15.0, Q.value(q, 'NetSideArea')
    assert_in_delta 4.5, Q.value(q, 'NetVolume')
    assert_in_delta 1.5, Q.value(q, 'GrossFootprintArea')
  end

  def test_missing_volume_is_skipped
    m = Fixtures.box_measures(1, 1, 1).merge(volume: nil)
    q = Q.for_type('column', m)
    assert_nil Q.value(q, 'NetVolume')
    assert_in_delta 1.0, Q.value(q, 'GrossVolume')
  end

  def test_slab
    q = Q.for_type('slab', Fixtures.box_measures(10, 8, 0.25))
    assert_in_delta 80.0, Q.value(q, 'GrossArea')
    assert_in_delta 0.25, Q.value(q, 'Width')
    assert_in_delta 20.0, Q.value(q, 'NetVolume')
    assert_in_delta 36.0, Q.value(q, 'Perimeter')
  end

  def test_format
    assert_equal '1,50', Q.format_number(1.5)
  end
end

class LevelListTest < Minitest::Test
  L = BIMSketch::LevelList

  def levels
    L.normalize([{ 'id' => 'L1', 'name' => 'Primo', 'elevation' => '3,2', 'height' => 3 },
                 { 'id' => 'L0', 'name' => 'Terra', 'elevation' => 0, 'height' => 3.2 }])
  end

  def test_normalize_sorts
    assert_equal %w[L0 L1], levels.map { |l| l['id'] }
    assert_in_delta 3.2, levels.last['elevation']
  end

  def test_for_z
    assert_equal 'L0', L.for_z(levels, 1.0)['id']
    assert_equal 'L1', L.for_z(levels, 3.195)['id']
    assert_equal 'L0', L.for_z(levels, -2)['id']
  end

  def test_build_next
    n = L.build_next(levels)
    assert_equal 'L2', n['id']
    assert_in_delta 6.2, n['elevation']
  end

  def test_empty_falls_back
    assert_equal 'L0', L.normalize([]).first['id']
  end
end

class RecordsTest < Minitest::Test
  R = BIMSketch::Records
  LEVELS = BIMSketch::LevelList.default

  def test_schedule_and_csv
    rows = R.schedule_rows([Fixtures.wall_record], LEVELS)
    assert_equal 'Muro', rows.first['type']
    assert_in_delta 15.0, rows.first['area']
    assert_in_delta 4.5, rows.first['volume']
    csv = R.to_csv(rows)
    assert csv.start_with?("﻿")
    assert_includes csv, '4,500'
    assert_equal 1, R.totals(rows).size
  end

  def test_ifc_element_mapping
    el = R.to_ifc_element(Fixtures.wall_record, LEVELS)
    assert_equal 'IfcWall', el[:ifc_class]
    pset = el[:psets].find { |p| p[:name] == 'Pset_WallCommon' }
    assert(pset[:props].any? { |p| p[:name] == 'ThermalTransmittance' && (p[:value] - 0.28).abs < 1e-9 })
    assert(el[:psets].any? { |p| p[:name] == R::CUSTOM_PSET })
    assert_equal 'L0', el[:storey_id]
  end

  def test_checker
    a = Fixtures.wall_record
    b = Fixtures.wall_record(guid: a[:guid], level: 'missing')
    door = Fixtures.wall_record.merge(type: 'door', host: 'nope')
    issues = BIMSketch::Checker.analyze([a, b, door], LEVELS, unclassified_count: 2)
    codes = issues.map { |i| i[:code] }
    assert_includes codes, 'duplicate_guid'
    assert_includes codes, 'no_level'
    assert_includes codes, 'orphan_opening'
    assert_includes codes, 'unclassified'
  end
end
