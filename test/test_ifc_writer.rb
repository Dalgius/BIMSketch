# frozen_string_literal: true

require_relative 'test_helper'

class IfcWriterTest < Minitest::Test
  # Number of attributes expected for each IFC4 entity written.
  ARITY = {
    'IFCPERSON' => 8, 'IFCORGANIZATION' => 5, 'IFCPERSONANDORGANIZATION' => 3,
    'IFCAPPLICATION' => 4, 'IFCOWNERHISTORY' => 8, 'IFCCARTESIANPOINT' => 1,
    'IFCDIRECTION' => 1, 'IFCAXIS2PLACEMENT3D' => 3, 'IFCGEOMETRICREPRESENTATIONCONTEXT' => 6,
    'IFCGEOMETRICREPRESENTATIONSUBCONTEXT' => 10, 'IFCSIUNIT' => 4, 'IFCUNITASSIGNMENT' => 1,
    'IFCPROJECT' => 9, 'IFCLOCALPLACEMENT' => 2, 'IFCSITE' => 14, 'IFCBUILDING' => 12,
    'IFCBUILDINGSTOREY' => 10, 'IFCRELAGGREGATES' => 6, 'IFCWALL' => 9, 'IFCDOOR' => 13,
    'IFCWINDOW' => 13, 'IFCSPACE' => 11, 'IFCCARTESIANPOINTLIST3D' => 1,
    'IFCTRIANGULATEDFACESET' => 5, 'IFCSTYLEDITEM' => 3, 'IFCCOLOURRGB' => 4,
    'IFCSURFACESTYLESHADING' => 2, 'IFCSURFACESTYLE' => 3, 'IFCSHAPEREPRESENTATION' => 4,
    'IFCPRODUCTDEFINITIONSHAPE' => 3, 'IFCPROPERTYSET' => 5, 'IFCPROPERTYSINGLEVALUE' => 4,
    'IFCRELDEFINESBYPROPERTIES' => 6, 'IFCELEMENTQUANTITY' => 6, 'IFCQUANTITYLENGTH' => 5,
    'IFCQUANTITYAREA' => 5, 'IFCQUANTITYVOLUME' => 5, 'IFCRELCONTAINEDINSPATIALSTRUCTURE' => 6,
    'IFCMATERIAL' => 3, 'IFCRELASSOCIATESMATERIAL' => 6, 'IFCSLAB' => 9,
    'IFCMATERIALLAYER' => 7, 'IFCMATERIALLAYERSET' => 3
  }.freeze

  def build
    levels = [{ 'id' => 'L0', 'name' => 'Piano Terra', 'elevation' => 0.0, 'height' => 3.0 },
              { 'id' => 'L1', 'name' => 'Piano Primo', 'elevation' => 3.0, 'height' => 3.0 }]
    w = BIMSketch::IfcWriter.new(project_name: 'Casa Rossi', building_name: 'Edificio A',
                                 author: 'Mario', latitude: 45.4642, longitude: 9.19)
    levels.each { |l| w.add_storey(id: l['id'], name: l['name'], elevation: l['elevation']) }
    wall = Fixtures.wall_record
    door = Fixtures.wall_record.merge(type: 'door', name: 'Porta', predefined: 'DOOR',
                                      measures: Fixtures.box_measures(0.9, 0.05, 2.1),
                                      mesh: Fixtures.box_mesh([1, 0.1, 0], 0.9, 0.05, 2.1),
                                      host: wall[:guid], material: 'Legno')
    slab = Fixtures.wall_record.merge(type: 'slab', name: 'Solaio', level: 'L1',
                                      predefined: 'FLOOR', z_min: 2.75,
                                      measures: Fixtures.box_measures(5, 4, 0.25),
                                      mesh: Fixtures.box_mesh([0, 0, 2.75], 5, 4, 0.25))
    space = Fixtures.wall_record.merge(type: 'space', name: 'Soggiorno', predefined: 'INTERNAL',
                                       material: nil, alpha: 0.25)
    layered = Fixtures.wall_record.merge(
      name: 'Muro stratificato', layer_set_name: 'Muro esterno',
      layers: [{ name: 'Cappotto', material: 'EPS', thickness: 0.1, function: 'insulation' },
               { name: 'Muratura', material: 'Laterizio', thickness: 0.3, function: 'structure' }],
      mesh_parts: [{ mesh: Fixtures.box_mesh([0, 5, 0], 5, 0.1, 3), color: [244, 214, 110], alpha: 1.0 },
                   { mesh: Fixtures.box_mesh([0, 5.1, 0], 5, 0.3, 3), color: [190, 110, 80], alpha: 1.0 }]
    )
    [wall, door, slab, space, layered].each do |r|
      w.add_element(BIMSketch::Records.to_ifc_element(r, levels))
    end
    w.to_s
  end

  def entities(text)
    text.scan(/^#(\d+)=([A-Z0-9]+)\((.*)\);$/).map { |id, type, args| [id.to_i, type, args] }
  end

  # Split top level STEP arguments, respecting strings and nested lists.
  def split_args(args)
    out = []
    depth = 0
    cur = +''
    in_str = false
    i = 0
    while i < args.size
      c = args[i]
      if in_str
        cur << c
        if c == "'"
          if args[i + 1] == "'"
            cur << "'"
            i += 1
          else
            in_str = false
          end
        end
      elsif c == "'"
        in_str = true
        cur << c
      elsif c == '('
        depth += 1
        cur << c
      elsif c == ')'
        depth -= 1
        cur << c
      elsif c == ',' && depth.zero?
        out << cur
        cur = +''
      else
        cur << c
      end
      i += 1
    end
    out << cur
  end

  def test_structure
    text = build
    assert text.start_with?('ISO-10303-21;')
    assert text.end_with?("END-ISO-10303-21;\n")
    assert_includes text, "FILE_SCHEMA(('IFC4'));"
    assert text.ascii_only?
  end

  def test_references_are_defined
    ents = entities(build)
    ids = ents.map(&:first)
    assert_equal ids.size, ids.uniq.size
    ents.each do |_, _, args|
      args.gsub(/'(?:[^']|'')*'/, '').scan(/#(\d+)/).flatten.map(&:to_i).each do |r|
        assert_includes ids, r
      end
    end
  end

  def test_arity
    entities(build).each do |_, type, args|
      next unless ARITY[type]

      assert_equal ARITY[type], split_args(args).size, "#{type}(#{args})"
    end
  end

  def test_layer_set_and_parts
    text = build
    assert_includes text, "IFCMATERIALLAYERSET("
    assert_includes text, "'Muro esterno'"
    assert_equal 2, text.scan('=IFCMATERIALLAYER(').size
    # Laterizio is both a plain material and a layer material: one IfcMaterial.
    assert_equal 1, text.scan("=IFCMATERIAL('Laterizio'").size
    # 4 elements with one mesh + 1 element with two parts.
    assert_equal 6, text.scan('=IFCTRIANGULATEDFACESET(').size
  end

  def test_content
    text = build
    %w[IFCWALL IFCDOOR IFCSLAB IFCSPACE IFCBUILDINGSTOREY IFCTRIANGULATEDFACESET
       IFCELEMENTQUANTITY IFCRELASSOCIATESMATERIAL].each { |t| assert_includes text, "=#{t}(" }
    assert_includes text, "'Pset_WallCommon'"
    assert_includes text, 'IFCBOOLEAN(.T.)'
    assert_includes text, "IFCLABEL('REI 120')"
    assert_includes text, '(45,27,51,120000)'
    # Il solaio è sul livello L1 (quota 3.0): z relativa = 2.75 - 3.0
    assert_includes text, '(0.,0.,-0.25)'
  end
end
