--[[============================================================================
main.lua
============================================================================]]--

-- tool registration

renoise.tool():add_menu_entry {
  name = "Pattern Editor:Pattern:Split...",
  invoke = function() 
     load_split_dialog()
  end
}

renoise.tool():add_keybinding {
  name = "Pattern Editor:Pattern:Split",
  invoke = function() load_split_dialog() end
}

--------------------------------------------------------------------------------
-- UI (dialog)
--------------------------------------------------------------------------------

function load_split_dialog()
  -- initiate view
  local vb = renoise.ViewBuilder()
  -- some constants for dimensions
  local MAX_PATTERN_LINES = renoise.song().selected_pattern.number_of_lines;
  local DIALOG_MARGIN = renoise.ViewBuilder.DEFAULT_DIALOG_MARGIN;
  local CONTENT_SPACING = renoise.ViewBuilder.DEFAULT_CONTROL_SPACING;
  local CONTENT_MARGIN = renoise.ViewBuilder.DEFAULT_CONTROL_MARGIN;
  local DEFAULT_DIALOG_BUTTON_HEIGHT = renoise.ViewBuilder.DEFAULT_DIALOG_BUTTON_HEIGHT

  local TEXT_ROW_WIDTH = 90;
  
  local split_part_value = 2;
  local process_automation = true;

  local split_dialog = renoise.app():show_custom_dialog(
    "Split Pattern",

    vb:column {
      margin = DIALOG_MARGIN,
      spacing = CONTENT_SPACING,
      uniform = true,

      vb:row {

        vb:text {
          width = TEXT_ROW_WIDTH,
          text = "Number of parts"
        },

        vb:valuebox {
          min = split_part_value,
          max = MAX_PATTERN_LINES,
          value = split_part_value,
          tooltip = "Splits selected pattern into this number of equal parts. "..
          "\nWARNING: This operation gets slow when number of parts is > 8",
          notifier = function(value) 
            split_part_value = value;
          end
        },
      },
      
      vb:row {
        vb:text {
          width = TEXT_ROW_WIDTH,
          text = "Split automation data"
        },
        vb:checkbox {
          value = process_automation,
          tooltip = "If checked, all automation data for the pattern is split up "..
                    "\nfor each new pattern that is created.  Unchecking this will "..
                    "\nslightly improve performance.  Only uncheck if you don't have "..
                    "\nautomation on this pattern!",
          notifier = function(value)
            process_automation = value;
          end
        }
      },
    
      vb:space { height = 2 },
      
      vb:button {
        text = "Split",
        width = 60,
        height = DEFAULT_DIALOG_BUTTON_HEIGHT,
        notifier = function()
          split(split_part_value, process_automation);
        end,
      }
    }
  )
  split_dialog:show()

end


--------------------------------------------------------------------------------
-- processing
--------------------------------------------------------------------------------

-- Performs the actual split process
-- num_parts - number of parts to split pattern into (equally)
-- process_automation - flag if checked that will split automation curves for
--                      part.
function split(num_parts, process_automation)

  --get the current pattern (this should be "prev pattern when handled inside loop)   
  local current_pattern = renoise.song().selected_pattern;
  
  --number of lines each new pattern will contain, also represents current line 
  -- when multiplied by num_parts  
  local lines_per_split = current_pattern.number_of_lines/num_parts;
  
  -- dialog valuebox range data should prevent this error from ever happening
  -- consider removing check
  if num_parts > current_pattern.number_of_lines then
    renoise.app():show_status('Warning: cannot split into more parts than number of lines in the pattern.');
    return
  end
  
  --STEP 1:  Create all the parts, will start as clones of current_pattern in sequence
  --clone current pattern by num_parts - 1 (since we will leave the original pattern 
  -- as the first part)
  for part = 1, num_parts-1 do
    local new_pattern_index =    
      renoise.song().sequencer:clone_range(
        renoise.song().selected_sequence_index + (part-1),
        renoise.song().selected_sequence_index + (part-1));
  end
  
  --cut the current pattern to be the length of the lines per split.  We are 
  -- now done processing the first part
  current_pattern.number_of_lines = lines_per_split; 
  
  --STEP 2:  Loop through each of the clones (skipping current) for automation
  --         processing
  for part = 1, num_parts-1 do
  
    --get the number of the line where we will begin our split
    local current_line = lines_per_split * part;
  
    --get the new pattern  
    local new_pattern = renoise.song().patterns[
      renoise.song().sequencer.pattern_sequence[
        renoise.song().selected_sequence_index+(part)]];
            
    local num_tracks = table.getn(new_pattern.tracks);
    
    -- only process automation if the checkbox is checked
    if process_automation then
      -- get the previous pattern, this is used to add a new automation point
      --  at the end in case there isn't one there already.
      local prev_pattern = renoise.song().patterns[
        renoise.song().sequencer.pattern_sequence[
          renoise.song().selected_sequence_index+(part-1)]];
  
      processAutomation(new_pattern, prev_pattern, current_line, num_tracks);
    end

    --STEP 3:  Crop all of the clones.  First, copy song data on every line of
    --         each part to the top of the pattern, and crop to the length
    --         of the line # per split part.  If split is an odd number or 
    --         pattern line count is odd, some line data WILL BE LOST.         
    resizeParts(new_pattern, current_line, num_tracks, lines_per_split);
    
  end
   
end

-- Copies line data for each part to the top and then crops the pattern
-- 
-- new_pattern - pattern we are currently processing
-- current_line - index pointing to first line of chunk we want to copy
-- num_tracks - count of number of tracks in pattern
-- lines_per_split - self explanatory
function resizeParts(new_pattern, current_line, num_tracks, lines_per_split)

    --copy notes from part to the top of the pattern
    for num_track = 1, num_tracks do
      local start_point = current_line + 1;
      local end_point = current_line + lines_per_split;
      for i = start_point,end_point do
        --if not --Commented out due to bug where splitter does not write
                 --over notes above it when section is blank
          -- optimization to copy only lines that have data
          --new_pattern.tracks[num_track]:line(i).is_empty
        --then 
          new_pattern.tracks[num_track]:line(i - current_line):copy_from(
            new_pattern.tracks[num_track]:line(i));
        --end
         
      end
      
    end
  
    -- crop the new pattern
    new_pattern.number_of_lines = lines_per_split;

end


-- Copies line data for each part to the top and then crops the pattern
-- 
-- new_pattern - pattern we are currently processing
-- prev_pattern - previous pattern we want to add automation point to at end
-- current_line - index pointing to first line of chunk we want to copy
-- num_tracks - count of number of tracks in pattern
function processAutomation(new_pattern, prev_pattern, current_line, num_tracks) 

  -- dealing with automation.
  -- first of all, let's create an intermediate point between the last point of previous
  -- pattern and the first of the new pattern, if it doesn't exists yet
  for num_track = 1, num_tracks do
  
    for num_auto = 1, table.getn(new_pattern.tracks[num_track].automation) do

      local points = new_pattern.tracks[num_track].automation[num_auto].points
    
      -- let's see if the line on which we are cutting already has a point
      -- in the curve; in such case, we are lucky and don't need to compute
      -- the intermediate point..
      if not 
        new_pattern.tracks[num_track].automation[num_auto]:has_point_at(current_line) 
      then
        -- let's see if the current automation curve has any point before the
        -- current_line and any point after current_line.
        local previous_point = 1
        local next_point = table.getn(points)

        for point = 1, table.getn(points) do
        
          if 
            points[point].time < current_line and 
            previous_point < points[point].time 
          then
            -- get the highest line which is less than current_line
            previous_point = point
          end 
      
          if 
            points[point].time > current_line and 
            next_point > points[point].time 
          then
            -- get the lowest line which is greater than current_line
            next_point = point        
          end
    
        end
      
        -- now create the transition point
        local transition_time = current_line
        local transition_value

        if previous_point == next_point then
          transition_value = points[previous_point].value
        else
          transition_value = 
            points[previous_point].value + 
            (points[next_point].value - points[previous_point].value) *
            (current_line - points[previous_point].time) /  
            (points[next_point].time - points[previous_point].time)
        end
        
        new_pattern.tracks[num_track].automation[num_auto]:add_point_at(current_line+1,transition_value)
        prev_pattern.tracks[num_track].automation[num_auto]:add_point_at(current_line,transition_value)

      else

        for point = 1, table.getn(points) do
          if points[point].time == current_line then
            new_pattern.tracks[num_track].automation[num_auto]:add_point_at(current_line+1,points[point].value)
            point = table.getn(points) -- break
          end
        end

      end

      -- delete any point which is before the current_line
      for point = 1, table.getn(points) do
      
        if points[point].time < current_line + 1 then
          new_pattern.tracks[num_track].automation[num_auto]:remove_point_at(points[point].time)
          point = point - 1
        end
    
      end
    
      -- refresh copy after deletion  
      points = new_pattern.tracks[num_track].automation[num_auto].points
    
      -- shift back all the points after the current_line
      for point = 1, table.getn(points) do

        local auto_time = points[point].time - current_line
        local auto_value = points[point].value

        new_pattern.tracks[num_track].automation[num_auto]:remove_point_at(points[point].time)      
        new_pattern.tracks[num_track].automation[num_auto]:add_point_at(auto_time,auto_value)
        
      end
  
    end
  
  end

end

