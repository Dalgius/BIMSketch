# frozen_string_literal: true

require 'minitest/autorun'

CORE = File.expand_path('../src/bimsketch/core', __dir__)
%w[element_types quantities guid level_list step ifc_writer records wall_profile wall_joint wall_types opening_types].each do |f|
  require File.join(CORE, f)
end

module Fixtures
  module_function

  # Box mesh (12 triangles) with the given size in meters at origin o.
  def box_mesh(o, sx, sy, sz)
    x, y, z = o
    pts = [[x, y, z], [x + sx, y, z], [x + sx, y + sy, z], [x, y + sy, z],
           [x, y, z + sz], [x + sx, y, z + sz], [x + sx, y + sy, z + sz], [x, y + sy, z + sz]]
    tris = [[0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7], [0, 1, 5], [0, 5, 4],
            [1, 2, 6], [1, 6, 5], [2, 3, 7], [2, 7, 6], [3, 0, 4], [3, 4, 7]]
    { points: pts, triangles: tris }
  end

  def box_measures(sx, sy, sz)
    { length: sx, width: sy, height: sz, volume: sx * sy * sz, perimeter: 2 * (sx + sy),
      areas: { 'px' => sy * sz, 'nx' => sy * sz, 'py' => sx * sz, 'ny' => sx * sz,
               'pz' => sx * sy, 'nz' => sx * sy } }
  end

  def wall_record(guid: BIMSketch::Guid.generate, level: 'L0')
    { guid: guid, type: 'wall', name: 'Muro nord', object_type: 'Laterizio 30',
      predefined: 'STANDARD', level: level, material: 'Laterizio',
      props: { 'LoadBearing' => true, 'FireRating' => 'REI 120', 'ThermalTransmittance' => '0,28' },
      custom: { 'Codice' => 'M-01' }, measures: box_measures(5.0, 0.3, 3.0),
      mesh: box_mesh([0, 0, 0], 5.0, 0.3, 3.0), color: [214, 206, 190], alpha: 1.0,
      solid: true, z_min: 0.0 }
  end
end
