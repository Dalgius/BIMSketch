# frozen_string_literal: true

module BIMSketch
  # Catalogo dei tipi di elemento BIM supportati e relativa mappatura IFC4.
  # Modulo puro Ruby: non dipende dalle API di SketchUp.
  module ElementTypes
    # Definizione di una proprietà di un Property Set.
    #   type: :label, :text, :boolean, :real, :integer, :length, :area,
    #         :count, :thermal (trasmittanza termica W/m²K)
    Prop = Struct.new(:name, :label, :type, :default)

    # Definizione di una quantità di un Quantity Set.
    #   measure: chiave della misura calcolata (vedi Quantities)
    #   kind:    :length, :area, :volume
    Qty = Struct.new(:name, :label, :measure, :kind)

    Type = Struct.new(:key, :label, :plural, :ifc_class, :color, :alpha,
                      :predefined, :pset, :props, :qto, :quantities,
                      :schedule_area, :needs_volume)

    def self.p(name, label, type, default = nil)
      Prop.new(name, label, type, default)
    end

    def self.q(name, label, measure, kind)
      Qty.new(name, label, measure, kind)
    end

    REFERENCE = p('Reference', 'Riferimento', :label)
    IS_EXTERNAL = p('IsExternal', 'Esterno', :boolean, false)
    LOAD_BEARING = p('LoadBearing', 'Portante', :boolean, false)
    FIRE_RATING = p('FireRating', 'Resistenza al fuoco (es. REI 60)', :label)
    ACOUSTIC = p('AcousticRating', 'Classe acustica', :label)
    THERMAL = p('ThermalTransmittance', 'Trasmittanza U (W/m²K)', :thermal)

    LIST = [
      Type.new('wall', 'Muro', 'Muri', 'IfcWall', [214, 206, 190], 1.0,
               %w[STANDARD SOLIDWALL PARTITIONING SHEAR PARAPET ELEMENTEDWALL NOTDEFINED],
               'Pset_WallCommon',
               [REFERENCE, LOAD_BEARING, IS_EXTERNAL, FIRE_RATING, ACOUSTIC, THERMAL,
                p('Combustible', 'Combustibile', :boolean, false),
                p('Compartmentation', 'Compartimentazione', :boolean, false)],
               'Qto_WallBaseQuantities',
               [q('Length', 'Lunghezza', :length, :length),
                q('Width', 'Spessore', :width, :length),
                q('Height', 'Altezza', :height, :length),
                q('GrossFootprintArea', 'Impronta lorda', :footprint_area, :area),
                q('GrossSideArea', 'Superficie laterale lorda', :gross_side_area, :area),
                q('NetSideArea', 'Superficie laterale netta', :net_side_area, :area),
                q('GrossVolume', 'Volume lordo', :gross_volume, :volume),
                q('NetVolume', 'Volume netto', :volume, :volume)],
               'NetSideArea', true),
      Type.new('slab', 'Solaio', 'Solai', 'IfcSlab', [180, 180, 180], 1.0,
               %w[FLOOR ROOF LANDING BASESLAB NOTDEFINED],
               'Pset_SlabCommon',
               [REFERENCE, LOAD_BEARING, IS_EXTERNAL, FIRE_RATING, ACOUSTIC, THERMAL,
                p('Combustible', 'Combustibile', :boolean, false)],
               'Qto_SlabBaseQuantities',
               [q('Width', 'Spessore', :height, :length),
                q('GrossArea', 'Superficie', :top_area, :area),
                q('Perimeter', 'Perimetro', :perimeter, :length),
                q('GrossVolume', 'Volume lordo', :prism_volume, :volume),
                q('NetVolume', 'Volume netto', :volume, :volume)],
               'GrossArea', true),
      Type.new('column', 'Pilastro', 'Pilastri', 'IfcColumn', [160, 160, 170], 1.0,
               %w[COLUMN PILASTER NOTDEFINED],
               'Pset_ColumnCommon',
               [REFERENCE, LOAD_BEARING, IS_EXTERNAL, FIRE_RATING, THERMAL],
               'Qto_ColumnBaseQuantities',
               [q('Length', 'Altezza', :height, :length),
                q('CrossSectionArea', 'Area sezione', :footprint_area, :area),
                q('OuterSurfaceArea', 'Superficie esterna', :side_area, :area),
                q('GrossVolume', 'Volume lordo', :gross_volume, :volume),
                q('NetVolume', 'Volume netto', :volume, :volume)],
               'CrossSectionArea', true),
      Type.new('beam', 'Trave', 'Travi', 'IfcBeam', [150, 150, 160], 1.0,
               %w[BEAM JOIST LINTEL T_BEAM HOLLOWCORE NOTDEFINED],
               'Pset_BeamCommon',
               [REFERENCE, LOAD_BEARING, IS_EXTERNAL, FIRE_RATING,
                p('Span', 'Luce (m)', :length)],
               'Qto_BeamBaseQuantities',
               [q('Length', 'Lunghezza', :length, :length),
                q('CrossSectionArea', 'Area sezione', :cross_section_yz, :area),
                q('OuterSurfaceArea', 'Superficie esterna', :surface_area, :area),
                q('GrossVolume', 'Volume lordo', :gross_volume, :volume),
                q('NetVolume', 'Volume netto', :volume, :volume)],
               'CrossSectionArea', true),
      Type.new('door', 'Porta', 'Porte', 'IfcDoor', [139, 94, 60], 1.0,
               %w[DOOR GATE TRAPDOOR NOTDEFINED],
               'Pset_DoorCommon',
               [REFERENCE, IS_EXTERNAL, FIRE_RATING, ACOUSTIC, THERMAL,
                p('SecurityRating', 'Classe antieffrazione', :label),
                p('HandicapAccessible', 'Accessibile disabili', :boolean, false),
                p('FireExit', 'Uscita di sicurezza', :boolean, false),
                p('SelfClosing', 'Autochiudente', :boolean, false),
                p('SmokeStop', 'Tenuta fumi', :boolean, false)],
               'Qto_DoorBaseQuantities',
               [q('Width', 'Larghezza', :length, :length),
                q('Height', 'Altezza', :height, :length),
                q('Area', 'Superficie', :opening_area, :area)],
               'Area', false),
      Type.new('window', 'Finestra', 'Finestre', 'IfcWindow', [120, 170, 220], 0.45,
               %w[WINDOW SKYLIGHT LIGHTDOME NOTDEFINED],
               'Pset_WindowCommon',
               [REFERENCE, IS_EXTERNAL, FIRE_RATING, ACOUSTIC, THERMAL,
                p('SecurityRating', 'Classe antieffrazione', :label),
                p('GlazingAreaFraction', 'Frazione vetrata (0-1)', :real),
                p('SmokeStop', 'Tenuta fumi', :boolean, false)],
               'Qto_WindowBaseQuantities',
               [q('Width', 'Larghezza', :length, :length),
                q('Height', 'Altezza', :height, :length),
                q('Area', 'Superficie', :opening_area, :area)],
               'Area', false),
      Type.new('roof', 'Copertura', 'Coperture', 'IfcRoof', [170, 90, 70], 1.0,
               %w[FLAT_ROOF SHED_ROOF GABLE_ROOF HIP_ROOF MANSARD_ROOF BARREL_ROOF
                  DOME_ROOF FREEFORM NOTDEFINED],
               'Pset_RoofCommon',
               [REFERENCE, IS_EXTERNAL, FIRE_RATING, THERMAL],
               'Qto_RoofBaseQuantities',
               [q('GrossArea', 'Superficie lorda', :top_area, :area),
                q('ProjectedArea', 'Superficie proiettata', :footprint_area, :area),
                q('NetVolume', 'Volume', :volume, :volume)],
               'GrossArea', false),
      Type.new('stair', 'Scala', 'Scale', 'IfcStair', [190, 190, 175], 1.0,
               %w[STRAIGHT_RUN_STAIR TWO_STRAIGHT_RUN_STAIR QUARTER_TURN_STAIR
                  HALF_TURN_STAIR SPIRAL_STAIR NOTDEFINED],
               'Pset_StairCommon',
               [REFERENCE, IS_EXTERNAL, FIRE_RATING,
                p('NumberOfRiser', 'Numero alzate', :count),
                p('NumberOfTreads', 'Numero pedate', :count),
                p('RiserHeight', 'Alzata (m)', :length),
                p('TreadLength', 'Pedata (m)', :length),
                p('HandicapAccessible', 'Accessibile disabili', :boolean, false),
                p('FireExit', 'Via di fuga', :boolean, false)],
               'Qto_StairBaseQuantities',
               [q('Length', 'Lunghezza', :length, :length),
                q('NetVolume', 'Volume', :volume, :volume)],
               nil, false),
      Type.new('railing', 'Parapetto', 'Parapetti', 'IfcRailing', [90, 90, 90], 1.0,
               %w[HANDRAIL GUARDRAIL BALUSTRADE NOTDEFINED],
               'Pset_RailingCommon',
               [REFERENCE, IS_EXTERNAL, p('Height', 'Altezza (m)', :length)],
               'Qto_RailingBaseQuantities',
               [q('Length', 'Lunghezza', :length, :length)],
               nil, false),
      Type.new('covering', 'Rivestimento', 'Rivestimenti', 'IfcCovering', [230, 220, 200], 1.0,
               %w[CEILING FLOORING CLADDING ROOFING MOLDING SKIRTINGBOARD INSULATION
                  MEMBRANE SLEEVING WRAPPING NOTDEFINED],
               'Pset_CoveringCommon',
               [REFERENCE, IS_EXTERNAL, FIRE_RATING, ACOUSTIC, THERMAL,
                p('Finish', 'Finitura', :label)],
               'Qto_CoveringBaseQuantities',
               [q('Width', 'Spessore', :height, :length),
                q('GrossArea', 'Superficie', :top_area, :area)],
               'GrossArea', false),
      Type.new('footing', 'Fondazione', 'Fondazioni', 'IfcFooting', [140, 140, 140], 1.0,
               %w[PAD_FOOTING STRIP_FOOTING PILE_CAP FOOTING_BEAM CAISSON_FOUNDATION NOTDEFINED],
               'Pset_FootingCommon',
               [REFERENCE, LOAD_BEARING],
               'Qto_FootingBaseQuantities',
               [q('Length', 'Lunghezza', :length, :length),
                q('Width', 'Larghezza', :width, :length),
                q('Height', 'Altezza', :height, :length),
                q('NetVolume', 'Volume', :volume, :volume)],
               nil, true),
      Type.new('furniture', 'Arredo', 'Arredi', 'IfcFurniture', [200, 170, 120], 1.0,
               %w[CHAIR TABLE DESK BED FILECABINET SHELF SOFA NOTDEFINED],
               'Pset_FurnitureTypeCommon',
               [REFERENCE, p('Style', 'Stile', :label)],
               nil, [], nil, false),
      Type.new('space', 'Spazio', 'Spazi', 'IfcSpace', [120, 200, 140], 0.25,
               %w[SPACE PARKING INTERNAL EXTERNAL NOTDEFINED],
               'Pset_SpaceCommon',
               [REFERENCE, IS_EXTERNAL,
                p('PubliclyAccessible', 'Accessibile al pubblico', :boolean, false),
                p('HandicapAccessible', 'Accessibile disabili', :boolean, false)],
               'Qto_SpaceBaseQuantities',
               [q('Height', 'Altezza', :height, :length),
                q('GrossFloorArea', 'Superficie lorda', :footprint_area, :area),
                q('NetFloorArea', 'Superficie calpestabile', :footprint_area, :area),
                q('GrossVolume', 'Volume', :volume, :volume)],
               'NetFloorArea', false),
      Type.new('proxy', 'Elemento generico', 'Elementi generici', 'IfcBuildingElementProxy',
               [200, 200, 200], 1.0,
               %w[ELEMENT COMPLEX PARTIAL NOTDEFINED],
               'Pset_BuildingElementProxyCommon',
               [REFERENCE, LOAD_BEARING, IS_EXTERNAL, FIRE_RATING, THERMAL],
               nil, [], nil, false)
    ].freeze

    BY_KEY = LIST.each_with_object({}) { |t, h| h[t.key] = t }.freeze

    module_function

    def all
      LIST
    end

    def [](key)
      BY_KEY[key.to_s]
    end

    def keys
      LIST.map(&:key)
    end

    def labels
      LIST.map(&:label)
    end

    def key_for_label(label)
      t = LIST.find { |x| x.label == label }
      t && t.key
    end

    # Nome del layer/tag SketchUp usato per gli elementi del tipo.
    def tag_name(key)
      t = self[key]
      t ? "BIM - #{t.plural}" : 'BIM - Altro'
    end

    # Converte il valore grezzo (stringa da dialog, numero, booleano) nel tipo
    # previsto dalla proprietà. Restituisce nil per valori vuoti/non validi.
    def coerce(prop_type, value)
      return nil if value.nil?
      return nil if value.is_a?(String) && value.strip.empty?

      case prop_type
      when :boolean
        return value if value == true || value == false

        %w[true 1 si sì yes vero].include?(value.to_s.strip.downcase)
      when :integer, :count
        Integer(value.to_s.strip, 10)
      when :real, :length, :area, :thermal
        Float(value.to_s.strip.tr(',', '.'))
      else
        value.to_s
      end
    rescue ArgumentError, TypeError
      nil
    end

    # Descrizione serializzabile (per i dialog HTML).
    def to_h(type)
      {
        'key' => type.key,
        'label' => type.label,
        'ifc' => type.ifc_class,
        'predefined' => type.predefined,
        'pset' => type.pset,
        'props' => type.props.map do |pr|
          { 'name' => pr.name, 'label' => pr.label, 'type' => pr.type.to_s,
            'default' => pr.default }
        end
      }
    end
  end
end
