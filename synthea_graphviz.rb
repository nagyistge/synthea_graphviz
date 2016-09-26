#!/usr/bin/ruby

require 'graphviz'
require 'synthea'

# color (true) or black & white (false)
COLOR = true

def generateRulesBasedGraph()
  # Create a new graph
  g = GraphViz.new( :G, :type => :digraph )

  # Create the list of items
  items = []
  modules = {}
  Synthea::Rules.metadata.each do |key,rule|
    items << key
    items << rule[:inputs]
    items << rule[:outputs]
    modules[ rule[:module_name] ] = true
  end
  items = items.flatten.uniq

  # Choose a color for each module
  # available_colors = GraphViz::Utils::Colors::COLORS.keys
  available_colors = ['palevioletred','orange','lightgoldenrod','palegreen','lightblue','lavender','purple']
  modules.keys.each_with_index do |key,index|
    modules[key] = available_colors[index]
  end
  attribute_color = 'grey'

  # Create a node for each item
  nodes = {}
  items.each{|i|nodes[i]=g.add_node(i.to_s)}

  # Make items that are not rules boxes
  components = nodes.keys - Synthea::Rules.metadata.keys
  components.each do |i|
    nodes[i]['shape']='Box'
    if COLOR
      nodes[i]['color']=attribute_color
      nodes[i]['style']='filled'
    end
  end

  # Create the edges
  edges = []

  Synthea::Rules.metadata.each do |key,rule|
    node = nodes[key]
    if COLOR
      node['color'] = modules[rule[:module_name]]
      node['style'] = 'filled'
    end
    begin
      rule[:inputs].each do |input|
        other = nodes[input]
        if !edges.include?("#{input}:#{key}")
          g.add_edge( other, node)
          edges << "#{input}:#{key}"
        end
      end
      rule[:outputs].each do |output|
        other = nodes[output]
        if !edges.include?("#{key}:#{output}")
          g.add_edge( node, other)
          edges << "#{key}:#{output}"
        end
      end
    rescue Exception => e
      binding.pry
    end
  end

  # Generate output image
  g.output( :png => "output/synthea_rules.png" )
end

def generateWorkflowBasedGraphs()
  Dir.glob('../synthea/lib/generic/modules/*.json') do |wf_file|
    # Create a new graph
    g = GraphViz.new( :G, :type => :digraph )

    # Create nodes based on states
    nodeMap = {}
    wf = JSON.parse(File.read(wf_file))
    wf['states'].each do |name, state|
      node = g.add_nodes(name, {'shape'=> 'record', 'style'=> 'rounded'})
      details = ''
      case state['type']
      when 'Initial', 'Terminal'
        node['color'] = 'black'
        node['style'] = 'rounded,filled'
        node['fontcolor'] = 'white'
      when 'Guard'
        details = "Allow if " + logicDetails(state['allow'])
      when 'Delay'
        if state.has_key? 'range'
          r = state['range']
          details = "#{r['low']} - #{r['high']} #{r['unit']}"
        elsif state.has_key? 'exact'
          e = state['exact']
          details = "#{e['quantity']} #{e['unit']}"
        end 
      when 'Encounter'
        if state['wellness']
          details = 'Wait for regularly scheduled wellness encounter'
        end
      when 'SetAttribute'
        v = state['value']
        details = "Set '#{state['attribute']}' = #{v ? "'#{v}'" : 'nil'}"
      end

      # Things common to many states
      if state.has_key? 'codes'
        state['codes'].each do |code|
          details = details + code['system'] + "[" + code['code'] + "]: " + code['display'] + "\\l"
        end
      end
      if state.has_key? 'target_encounter'
        verb = 'Perform'
        case state['type']
        when 'ConditionOnset'
          verb = 'Diagnose'
        when 'MedicationOrder'
          verb = 'Prescribe'
        end
        details = details + verb + " at " + state['target_encounter'] + "\\l"
      end
      if state.has_key? 'reason'
        details = details + "Reason: " + state['reason'] + "\\l"
      end
      if state.has_key? 'medication_order'
        details = details + "Prescribed at: #{state['medication_order']}\\l"
      end
      if state.has_key? 'assign_to_attribute'
        details = details + "Assign to Attribute: '#{state['assign_to_attribute']}'\\l"
      end
      if state.has_key? 'referenced_by_attribute'
        details = details + "Referenced By Attribute: '#{state['referenced_by_attribute']}'\\l"
      end
      if details.empty?
        node['label'] = (name == state['type']) ? name : "{ #{name} | #{state['type']} }"
      else
        node['label'] = "{ #{name} | { #{state['type']} | #{details} } }"
      end
      nodeMap[name] = node
    end

    # Create the edges based on the transitions
    wf['states'].each do |name, state|
      if state.has_key? 'direct_transition'
        g.add_edges( nodeMap[name], nodeMap[state['direct_transition']] )
      elsif state.has_key? 'distributed_transition'
        state['distributed_transition'].each do |t|
          pct = t['distribution'] * 100
          pct = pct.to_i if pct == pct.to_i
          g.add_edges( nodeMap[name], nodeMap[t['transition']], {'label'=> "#{pct}%"})
        end
      elsif state.has_key? 'conditional_transition'
        state['conditional_transition'].each_with_index do |t,i|
          cnd = t.has_key?('condition') ? logicDetails(t['condition']) : 'else'
          g.add_edges( nodeMap[name], nodeMap[t['transition']], {'label'=> "#{i+1}. #{cnd}"})
        end
      elsif state.has_key? 'complex_transition'
        transitions = Hash.new() { |hsh, key| hsh[key] = [] }

        state['complex_transition'].each do |t|
          cond = t.has_key?('condition') ? logicDetails(t['condition']) : 'else'
          t['distributions'].each do |dist|
            pct = dist['distribution'] * 100
            pct = pct.to_i if pct == pct.to_i
            nodes = [name, dist['transition']]
            transitions[nodes] << "#{cond}: #{pct}%"
          end
        end

        transitions.each do |nodes, labels|
          g.add_edges( nodeMap[nodes[0]], nodeMap[nodes[1]], {'label'=> labels.join(',\n')})
        end
      end
    end

    # Generate output image
    g.output( :png => "output/#{wf['name']}.png" )
  end
end

def logicDetails(logic)
  case logic['condition_type']
  when 'And', 'Or'
    subs = logic['conditions'].map do |c|
      if ['And','Or'].include?(c['condition_type'])
        "(\\l" + logicDetails(c) + ")\\l"
      else 
        logicDetails(c)
      end
    end
    subs.join(logic['condition_type'].downcase + ' ')
  when 'Not'
    c = logic['condition']
    if ['And','Or'].include?(c['condition_type'])
      "not (\\l" + logicDetails(c) + ")\\l"
    else
      "not " + logicDetails(c)
    end
  when 'Gender'
    "gender is '#{logic['gender']}'\\l"
  when 'Age'
    "age \\#{logic['operator']} #{logic['quantity']} #{logic['unit']}\\l"
  when 'Socioeconomic Status'
    "#{logic['category']} Socioeconomic Status\\l"
  when 'Date'
    "Year is \\#{logic['operator']} #{logic['year']}\\l"
  when 'Attribute'
    v = logic['value']
    if !v.nil?
      "Attribute: '#{logic['attribute']}' is \\#{logic['operator']} #{v}\\l"
    else
      "Attribute: '#{logic['attribute']}' \\#{logic['operator']}\\l"
    end
  else
    "UNSUPPORTED_CONDITION(#{logic['condition_type']})\\l"
  end
end

puts 'Rendering graphs to `./output` folder...'
generateRulesBasedGraph()
generateWorkflowBasedGraphs()
puts 'Done.'