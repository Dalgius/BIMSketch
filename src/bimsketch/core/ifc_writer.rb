# frozen_string_literal: true

require_relative 'step'
require_relative 'guid'

module BIMSketch
  # Scrittore di file IFC4 (STEP Physical File, Reference View).
  # Modulo puro Ruby: riceve dati già convertiti in metri e produce il testo
  # del file. La geometria è esportata come IfcTriangulatedFaceSet.
  #
  # Elemento (hash):
  #   guid:, ifc_class:, name:, description:, object_type:, predefined:, tag:,
  #   storey_id:, material:, color: [r,g,b] (0..1), transparency: (0..1),
  #   mesh: { points: [[x,y,z], ...], triangles: [[i,j,k], ...] }  (indici 0-based, m)
  #   mesh_parts: [{ mesh:, color:, transparency: }]  (in alternativa a mesh: una
  #               geometria per parte, ognuna con il suo colore, es. gli strati di un muro)
  #   layers: [{ name:, material:, thickness: (m), category: }], layer_set_name:
  #           (stratigrafia: IfcMaterialLayerSet al posto del materiale singolo)
  #   psets: [{ name:, props: [{ name:, type:, value: }] }]
  #   qtos:  [{ name:, quantities: [{ name:, kind:, value: }] }]
  #   overall_width:, overall_height:  (solo porte/finestre)
  #   operation: OperationType delle porte / PartitioningType delle finestre
  class IfcWriter
    include Step

    # Classi con la firma standard di IfcBuildingElement (9 attributi).
    STANDARD_ELEMENTS = %w[
      IFCWALL IFCSLAB IFCCOLUMN IFCBEAM IFCROOF IFCSTAIR IFCRAILING IFCCOVERING
      IFCFOOTING IFCFURNITURE IFCBUILDINGELEMENTPROXY IFCMEMBER IFCPLATE
    ].freeze

    PROP_TYPES = {
      label: 'IFCLABEL', text: 'IFCTEXT', boolean: 'IFCBOOLEAN', real: 'IFCREAL',
      integer: 'IFCINTEGER', count: 'IFCCOUNTMEASURE', length: 'IFCLENGTHMEASURE',
      area: 'IFCAREAMEASURE', thermal: 'IFCTHERMALTRANSMITTANCEMEASURE'
    }.freeze

    QTY_TYPES = {
      length: 'IFCQUANTITYLENGTH', area: 'IFCQUANTITYAREA', volume: 'IFCQUANTITYVOLUME'
    }.freeze

    attr_reader :storeys, :elements

    def initialize(project_name: 'Progetto', site_name: 'Sito', building_name: 'Edificio',
                   author: '', organization: 'BIMSketch', application_version: '1.0.0',
                   file_name: 'model.ifc', latitude: nil, longitude: nil, timestamp: Time.now)
      @project_name = project_name
      @site_name = site_name
      @building_name = building_name
      @author = author
      @organization = organization
      @app_version = application_version
      @file_name = file_name
      @latitude = latitude
      @longitude = longitude
      @timestamp = timestamp
      @storeys = []
      @elements = []
    end

    def add_storey(id:, name:, elevation:)
      @storeys << { id: id, name: name, elevation: elevation.to_f }
      self
    end

    def add_element(element)
      @elements << element
      self
    end

    def to_s
      @lines = []
      @next_id = 0
      @styles = {}
      @materials = {}
      write_header_entities
      write_spatial_structure
      write_elements
      header + @lines.join("\n") + "\nENDSEC;\nEND-ISO-10303-21;\n"
    end

    def write(path)
      File.open(path, 'wb') { |f| f.write(to_s) }
    end

    private

    def add(type, *args)
      @next_id += 1
      @lines << "##{@next_id}=#{type}(#{args.join(',')});"
      @next_id
    end

    def guid
      str(Guid.generate)
    end

    def header
      time = @timestamp.utc.strftime('%Y-%m-%dT%H:%M:%S')
      [
        'ISO-10303-21;',
        'HEADER;',
        "FILE_DESCRIPTION(('ViewDefinition [ReferenceView_V1.2]'),'2;1');",
        "FILE_NAME(#{str(@file_name)},'#{time}',(#{str(@author)}),(#{str(@organization)})," \
        "'BIMSketch #{@app_version}','BIMSketch per SketchUp','');",
        "FILE_SCHEMA(('IFC4'));",
        'ENDSEC;',
        'DATA;',
        ''
      ].join("\n")
    end

    def write_header_entities
      person = add('IFCPERSON', UNSET, str(@author.to_s.empty? ? nil : @author), UNSET,
                   UNSET, UNSET, UNSET, UNSET, UNSET)
      org = add('IFCORGANIZATION', UNSET, str(@organization), UNSET, UNSET, UNSET)
      person_org = add('IFCPERSONANDORGANIZATION', ref(person), ref(org), UNSET)
      app = add('IFCAPPLICATION', ref(org), str(@app_version), str('BIMSketch per SketchUp'),
                str('BIMSketch'))
      @owner = add('IFCOWNERHISTORY', ref(person_org), ref(app), UNSET, enum('NOTDEFINED'),
                   UNSET, UNSET, UNSET, int(@timestamp.to_i))

      @origin = add('IFCCARTESIANPOINT', list([real(0), real(0), real(0)]))
      z = add('IFCDIRECTION', list([real(0), real(0), real(1)]))
      x = add('IFCDIRECTION', list([real(1), real(0), real(0)]))
      @world = add('IFCAXIS2PLACEMENT3D', ref(@origin), ref(z), ref(x))
      context = add('IFCGEOMETRICREPRESENTATIONCONTEXT', UNSET, str('Model'), '3',
                    real(1.0e-5), ref(@world), UNSET)
      @body_context = add('IFCGEOMETRICREPRESENTATIONSUBCONTEXT', str('Body'), str('Model'),
                          DERIVED, DERIVED, DERIVED, DERIVED, ref(context), UNSET,
                          enum('MODEL_VIEW'), UNSET)

      units = [
        add('IFCSIUNIT', DERIVED, enum('LENGTHUNIT'), UNSET, enum('METRE')),
        add('IFCSIUNIT', DERIVED, enum('AREAUNIT'), UNSET, enum('SQUARE_METRE')),
        add('IFCSIUNIT', DERIVED, enum('VOLUMEUNIT'), UNSET, enum('CUBIC_METRE')),
        add('IFCSIUNIT', DERIVED, enum('PLANEANGLEUNIT'), UNSET, enum('RADIAN'))
      ]
      unit_assignment = add('IFCUNITASSIGNMENT', refs(units))
      @project = add('IFCPROJECT', guid, ref(@owner), str(@project_name), UNSET, UNSET,
                     UNSET, UNSET, refs([context]), ref(unit_assignment))
    end

    def placement(relative_to, z = 0.0)
      point = if z.zero?
                @origin
              else
                add('IFCCARTESIANPOINT', list([real(0), real(0), real(z)]))
              end
      axis = add('IFCAXIS2PLACEMENT3D', ref(point), UNSET, UNSET)
      add('IFCLOCALPLACEMENT', relative_to ? ref(relative_to) : UNSET, ref(axis))
    end

    def compound_angle(deg)
      return UNSET if deg.nil?

      sign = deg.negative? ? -1 : 1
      micro = (deg.abs * 3600 * 1_000_000).round
      d, micro = micro.divmod(3600 * 1_000_000)
      m, micro = micro.divmod(60 * 1_000_000)
      s, micro = micro.divmod(1_000_000)
      list([d, m, s, micro].map { |n| (n * sign).to_s })
    end

    def write_spatial_structure
      @storeys << { id: 'L0', name: 'Piano Terra', elevation: 0.0 } if @storeys.empty?

      site_placement = placement(nil)
      @site = add('IFCSITE', guid, ref(@owner), str(@site_name), UNSET, UNSET,
                  ref(site_placement), UNSET, UNSET, enum('ELEMENT'),
                  compound_angle(@latitude), compound_angle(@longitude), UNSET, UNSET, UNSET)
      building_placement = placement(site_placement)
      @building = add('IFCBUILDING', guid, ref(@owner), str(@building_name), UNSET, UNSET,
                      ref(building_placement), UNSET, UNSET, enum('ELEMENT'), UNSET, UNSET,
                      UNSET)
      @storey_entities = {}
      @storey_placements = {}
      @storeys.sort_by { |s| s[:elevation] }.each do |s|
        pl = placement(building_placement, s[:elevation])
        @storey_placements[s[:id]] = pl
        @storey_entities[s[:id]] = add('IFCBUILDINGSTOREY', guid, ref(@owner), str(s[:name]),
                                       UNSET, UNSET, ref(pl), UNSET, UNSET, enum('ELEMENT'),
                                       real(s[:elevation]))
      end
      add('IFCRELAGGREGATES', guid, ref(@owner), UNSET, UNSET, ref(@project), refs([@site]))
      add('IFCRELAGGREGATES', guid, ref(@owner), UNSET, UNSET, ref(@site), refs([@building]))
      add('IFCRELAGGREGATES', guid, ref(@owner), UNSET, UNSET, ref(@building),
          refs(@storey_entities.values))
    end

    def storey_for(element)
      s = @storeys.find { |x| x[:id] == element[:storey_id] }
      s || @storeys.min_by { |x| x[:elevation] }
    end

    def write_elements
      contained = Hash.new { |h, k| h[k] = [] }
      spaces = Hash.new { |h, k| h[k] = [] }
      by_material = Hash.new { |h, k| h[k] = [] }
      by_layer_set = Hash.new { |h, k| h[k] = [] }
      layer_sets = {}

      @elements.each do |el|
        storey = storey_for(el)
        id = write_element(el, storey)
        if el[:ifc_class].to_s.upcase == 'IFCSPACE'
          spaces[storey[:id]] << id
        else
          contained[storey[:id]] << id
        end
        mat = el[:material].to_s.strip
        layers = Array(el[:layers]).select { |l| l[:thickness].to_f.positive? }
        if layers.empty?
          by_material[mat] << id unless mat.empty?
        else
          key = [el[:layer_set_name].to_s,
                 layers.map { |l| [l[:name].to_s, l[:material].to_s, l[:thickness].to_f.round(6)] }]
          layer_sets[key] ||= [el[:layer_set_name], layers]
          by_layer_set[key] << id
        end
        write_psets(el, id)
        write_qtos(el, id)
      end

      contained.each do |sid, ids|
        add('IFCRELCONTAINEDINSPATIALSTRUCTURE', guid, ref(@owner), UNSET, UNSET, refs(ids),
            ref(@storey_entities[sid]))
      end
      spaces.each do |sid, ids|
        add('IFCRELAGGREGATES', guid, ref(@owner), UNSET, UNSET, ref(@storey_entities[sid]),
            refs(ids))
      end
      by_material.each do |name, ids|
        add('IFCRELASSOCIATESMATERIAL', guid, ref(@owner), UNSET, UNSET, refs(ids), ref(material(name)))
      end
      by_layer_set.each do |key, ids|
        name, layers = layer_sets[key]
        items = layers.map do |l|
          mat_name = l[:material].to_s.strip.empty? ? l[:name].to_s : l[:material].to_s
          add('IFCMATERIALLAYER', ref(material(mat_name)), real(l[:thickness]), UNSET, str(l[:name]),
              UNSET, str(l[:category]), UNSET)
        end
        set = add('IFCMATERIALLAYERSET', refs(items), str(name), UNSET)
        add('IFCRELASSOCIATESMATERIAL', guid, ref(@owner), UNSET, UNSET, refs(ids), ref(set))
      end
    end

    def material(name)
      @materials[name] ||= add('IFCMATERIAL', str(name), UNSET, UNSET)
    end

    def write_element(el, storey)
      cls = el[:ifc_class].to_s.upcase
      cls = 'IFCBUILDINGELEMENTPROXY' unless STANDARD_ELEMENTS.include?(cls) ||
                                             %w[IFCDOOR IFCWINDOW IFCSPACE].include?(cls)
      pl = placement(@storey_placements[storey[:id]])
      rep = write_representation(el, storey[:elevation])
      gid = Guid.valid?(el[:guid]) ? str(el[:guid]) : guid
      common = [gid, ref(@owner), str(el[:name]), str(el[:description]), str(el[:object_type]),
                ref(pl), rep ? ref(rep) : UNSET]
      predefined = el[:predefined].to_s.empty? ? 'NOTDEFINED' : el[:predefined]
      predefined = 'NOTDEFINED' if predefined == 'USERDEFINED' && el[:object_type].to_s.empty?
      case cls
      when 'IFCDOOR', 'IFCWINDOW'
        h = el[:overall_height] ? real(el[:overall_height]) : UNSET
        w = el[:overall_width] ? real(el[:overall_width]) : UNSET
        op = el[:operation].to_s =~ /\A[A-Z_]+\z/ ? enum(el[:operation]) : UNSET
        add(cls, *common, str(el[:tag]), h, w, enum(predefined), op, UNSET)
      when 'IFCSPACE'
        add(cls, *common, str(el[:long_name]), enum('ELEMENT'), enum(predefined), UNSET)
      else
        add(cls, *common, str(el[:tag]), enum(predefined))
      end
    end

    def write_representation(el, elevation)
      parts = el[:mesh_parts] || [{ mesh: el[:mesh], color: el[:color], transparency: el[:transparency] }]
      face_sets = parts.map do |part|
        mesh = part[:mesh]
        next nil unless mesh && mesh[:triangles] && !mesh[:triangles].empty?

        coords = mesh[:points].map do |p|
          list([real(p[0]), real(p[1]), real(p[2] - elevation)])
        end
        point_list = add('IFCCARTESIANPOINTLIST3D', list(coords))
        tris = mesh[:triangles].map { |t| list(t.map { |i| (i + 1).to_s }) }
        face_set = add('IFCTRIANGULATEDFACESET', ref(point_list), UNSET, UNSET, list(tris), UNSET)
        style = surface_style(part[:color], part[:transparency])
        add('IFCSTYLEDITEM', ref(face_set), refs([style]), UNSET) if style
        face_set
      end.compact
      return nil if face_sets.empty?

      shape = add('IFCSHAPEREPRESENTATION', ref(@body_context), str('Body'), str('Tessellation'),
                  refs(face_sets))
      add('IFCPRODUCTDEFINITIONSHAPE', UNSET, UNSET, refs([shape]))
    end

    def surface_style(color, transparency)
      return nil unless color

      key = (color.map { |c| c.to_f.round(3) } + [transparency.to_f.round(3)]).freeze
      @styles[key] ||= begin
        rgb = add('IFCCOLOURRGB', UNSET, real(key[0]), real(key[1]), real(key[2]))
        shading = add('IFCSURFACESTYLESHADING', ref(rgb), real(key[3]))
        add('IFCSURFACESTYLE', UNSET, enum('BOTH'), refs([shading]))
      end
    end

    def write_psets(el, element_id)
      Array(el[:psets]).each do |pset|
        props = Array(pset[:props]).map { |pr| property(pr) }.compact
        next if props.empty?

        ps = add('IFCPROPERTYSET', guid, ref(@owner), str(pset[:name]), UNSET, refs(props))
        add('IFCRELDEFINESBYPROPERTIES', guid, ref(@owner), UNSET, UNSET, refs([element_id]),
            ref(ps))
      end
    end

    def property(pr)
      value = pr[:value]
      return nil if value.nil? || (value.is_a?(String) && value.strip.empty?)

      type = (pr[:type] || :label).to_sym
      encoded = case type
                when :boolean then bool(value)
                when :integer then Integer(value.to_f.round).to_s
                when :count then value.is_a?(Integer) ? value.to_s : real(value)
                when :real, :length, :area, :thermal then real(value)
                else str(value)
                end
      ifc_type = PROP_TYPES[type] || 'IFCLABEL'
      add('IFCPROPERTYSINGLEVALUE', str(pr[:name]), UNSET, typed(ifc_type, encoded), UNSET)
    end

    def write_qtos(el, element_id)
      Array(el[:qtos]).each do |qto|
        qs = Array(qto[:quantities]).map do |q|
          type = QTY_TYPES[q[:kind].to_sym]
          next nil unless type && q[:value]

          add(type, str(q[:name]), UNSET, UNSET, real(q[:value]), UNSET)
        end.compact
        next if qs.empty?

        eq = add('IFCELEMENTQUANTITY', guid, ref(@owner), str(qto[:name]), UNSET, UNSET,
                 refs(qs))
        add('IFCRELDEFINESBYPROPERTIES', guid, ref(@owner), UNSET, UNSET, refs([element_id]),
            ref(eq))
      end
    end
  end
end
