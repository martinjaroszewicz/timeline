package require Tk

# Initialize variables
set tracks 4
set track_height 100
set timeline_width 1000
set timeline_start 20
set timeline_end [expr {$timeline_start + $timeline_width}]
set current_track 0
set dragging 0
set drag_item {}
set drag_start_x 0
set drag_start_y 0
set playing 0
set playhead_position $timeline_start
set playhead_speed 2
set pd_channel ""


# Modified data structures
array set points {} 
array set connections {} 

# Create main window
wm title . "Multitrack Timeline"
wm geometry . 1100x650

# Create canvas for timeline
canvas .c -width 1080 -height 580 -bg white
pack .c -padx 10 -pady 10


################################################################################
#                               Connect to Pure Data                           #
################################################################################

proc setup_pd_connection {} {
    global pd_channel
    if {$pd_channel eq ""} {
        if {[catch {open "|pdsend 3000 localhost" w} pd_channel]} {
            puts "Error opening connection to Pure Data: $pd_channel"
            set pd_channel ""
        } else {
            puts "Connection to Pure Data established."
            fconfigure $pd_channel -buffering line
        }
    }
}


################################################################################
#                            Set the ticks                                     #
################################################################################

set seconds_per_timeline 10
set pixels_per_second [expr {$timeline_width / $seconds_per_timeline}]
proc draw_timeline_ticks {} {
    global timeline_start timeline_end timeline_width tracks track_height seconds_per_timeline pixels_per_second

    set tick_y [expr {$tracks * $track_height + 15}]
    set label_y [expr {$tick_y + 15}]

    for {set i 0} {$i <= $seconds_per_timeline} {incr i} {
        set x [expr {$timeline_start + $i * $pixels_per_second}]
        
        # Draw tick mark
        .c create line $x $tick_y $x [expr {$tick_y + 5}] -fill black -tags ticks

        # Draw label
        .c create text $x $label_y -text "${i}s" -anchor n -tags ticks
    }
}

################################################################################
#                            Set the tempo                                     #
################################################################################

# Create playback controls
frame .controls
pack .controls -side bottom -pady 10
# Add BPM entry and label to the controls frame
label .controls.bpm_label -text "BPM:"
entry .controls.bpm_entry -width 5 -textvariable bpm -validate key -validatecommand {
    expr {[string is double %P] || [string length %P] == 0}
}
pack .controls.bpm_label .controls.bpm_entry -side left -padx 2

# META NAME Multitrack Timeline

# META DESCRIPTION A real-time multitrack timeline application for sending triggers 
# and continuous values to Pure Data (Pd). 
# Users can create and manipulate points across n tracks, interpolate values between points,
# connect points, and synchronize musical events with a playhead controlled by BPM. 
# Supports saving and loading timeline configurations.

# META AUTHOR Martin Jaros jarosmartin@duck.com


# Initialize BPM variable
set bpm 60

proc update_bpm {args} {
    global bpm
    if {![string is double $bpm] || $bpm <= 0} {
        set bpm 120  # Reset to default if invalid
    }
}

trace add variable bpm write update_bpm

################################################################################
#                           Create playback controls                           #
################################################################################


button .controls.play -text "Play" -command toggle_playback
button .controls.stop -text "Stop" -command stop_playback
label .controls.values -text "Value: " -width 30 -anchor w
pack .controls.play .controls.stop .controls.values -side left -padx 5

# Create playhead
.c create line $playhead_position 10 $playhead_position [expr {$tracks * $track_height + 10}] \
    -fill red -width 2 -tags playhead

proc toggle_playback {} {
    global playing playhead_position timeline_start
    set playing [expr {!$playing}]
    .controls.play configure -text [expr {$playing ? "Pause" : "Resume"}]
    if {$playing} {
        set playhead_position $playhead_position
        update_playhead
    }
}

proc stop_playback {} {
    global playing playhead_position timeline_start tracks track_height
    set playing 0
    set playhead_position $timeline_start
    .controls.play configure -text "Play"
    .c coords playhead $playhead_position 10 $playhead_position [expr {$tracks * $track_height + 10}]
}

proc update_playhead {} {
    global playing playhead_position timeline_end tracks track_height bpm timeline_width timeline_start

    if {$playing} {
        # Calculate pixels per frame based on BPM
        set beats_per_second [expr {$bpm / 60.0}]
        set pixels_per_beat [expr {$timeline_width / 10.0}]  
        set pixels_per_second [expr {$beats_per_second * $pixels_per_beat}]
        set pixels_per_frame [expr {$pixels_per_second / 60.0}]  

        set playhead_position [expr {$playhead_position + $pixels_per_frame}]
        
        if {$playhead_position > $timeline_end} {
            set playhead_position $timeline_start
        }

        .c coords playhead $playhead_position 10 $playhead_position [expr {$tracks * $track_height + 10}]
        update_values
        after 16 update_playhead
    }
}

proc update_bpm {args} {
    global bpm
    if {$bpm eq ""} {
        # Allow empty string for easier editing
        return
    }
    if {![string is double $bpm] || $bpm <= 0} {
        set bpm 60  # Reset to default if invalid
    }
}

# Add this trace after the BPM variable initialization
trace add variable bpm write update_bpm

# Bind the update_bpm procedure to the BPM entry widget
trace add variable bpm write update_bpm


# Modify the update_values procedure to use the new send_to_pd function
proc update_values {} {
    global points playhead_position tracks current_track connections
    array set track_values {}
    
    # For each track
    for {set track 0} {$track < $tracks} {incr track} {
        set track_values($track) -1
        
        # Skip if no points exist on this track
        if {![info exists points($track)] || [llength $points($track)] == 0} {
            continue
        }
        
        # First check connected segments
        set found_segment 0
        foreach key [array names connections] {
            lassign [split $key ","] conn_track x1 y1 x2 y2
            if {$conn_track == $track} {
                # If playhead is between these connected points
                if {$playhead_position >= $x1 && $playhead_position <= $x2} {
                    set found_segment 1
                    # Calculate interpolated value for connected points
                    set t [expr {double($playhead_position - $x1) / ($x2 - $x1)}]
                    set v1 [y_to_value $y1 $track]
                    set v2 [y_to_value $y2 $track]
                    set track_values($track) [expr {$v1 + ($v2 - $v1) * $t}]
                    break
                }
            }
        }
        
        # If not in a connected segment, check if we're exactly on a point
        if {!$found_segment} {
            foreach point $points($track) {
                set px [lindex $point 0]
                # Check if we're exactly on a point (within 1 pixel tolerance)
                if {abs($playhead_position - $px) < 1} {
                    set py [lindex $point 1]
                    set track_values($track) [y_to_value $py $track]
                    set found_segment 1
                    break
                }
            }
        }
        
        # If we're not on a point or between connected points, keep as -1
    }
    
    # Update display
    if {$track_values($current_track) != -1} {
        .controls.values configure -text "Value: [format %.1f $track_values($current_track)]"
    } else {
        .controls.values configure -text "Value: -"
    }
    
    # Send all track values to Pure Data
    send_to_pd track_values
}

proc send_to_pd {values_array} {
    global pd_channel tracks
    if {$pd_channel ne ""} {
        set message ""
        upvar $values_array values
        for {set i 0} {$i < $tracks} {incr i} {
            append message "track$i $values($i) "
        }
        
        if {[catch {puts $pd_channel "$message;"
                   flush $pd_channel} error]} {
            # Connection broke - try to reconnect
            catch {close $pd_channel}
            set pd_channel ""
            after 1000 setup_pd_connection
            puts "Lost connection to Pure Data. Attempting to reconnect..."
        }
    }
}

# Point manipulation procedures
proc add_point {x y} {
    global points current_track
    if {![info exists points($current_track)]} {
        set points($current_track) {}
    }
    lappend points($current_track) [list $x $y]
    set points($current_track) [lsort -index 0 -real $points($current_track)]
    set id [.c create oval [expr {$x-3}] [expr {$y-3}] [expr {$x+3}] [expr {$y+3}] \
        -fill red -tags "point point$current_track"]
    return $id
}

proc find_nearest_point {x y} {
    global points current_track
    set nearest_point {}
    set min_distance Inf
    
    if {[info exists points($current_track)]} {
        foreach point $points($current_track) {
            set px [lindex $point 0]
            set py [lindex $point 1]
            set distance [expr {sqrt(pow($x - $px, 2) + pow($y - $py, 2))}]
            if {$distance < $min_distance && ($px != $x || $py != $y)} {
                set min_distance $distance
                set nearest_point $point
            }
        }
    }
    return $nearest_point
}

# New procedure to connect points
proc connect_points {point1 point2} {
    global connections current_track
    
    # Create unique connection identifier
    set x1 [lindex $point1 0]
    set y1 [lindex $point1 1]
    set x2 [lindex $point2 0]
    set y2 [lindex $point2 1]
    
    # Sort points by x coordinate to ensure consistent connection identification
    if {$x1 > $x2} {
        set temp $point1
        set point1 $point2
        set point2 $temp
    }
    
    # Create connection key
    set connection_key "$current_track,$x1,$y1,$x2,$y2"
    
    if {![info exists connections($connection_key)]} {
        set line_id [.c create line $x1 $y1 $x2 $y2 -fill blue -width 2 -tags "connection connection$current_track"]
        set connections($connection_key) $line_id
        return $line_id
    }
    return {}
}

proc remove_point {x y} {
    global points current_track connections
    set detection_radius 5
    set found_point 0
    set point_to_remove {}
    
    if {[info exists points($current_track)]} {
        # First find the point to remove
        foreach point $points($current_track) {
            set px [lindex $point 0]
            set py [lindex $point 1]
            set distance [expr {sqrt(pow($x - $px, 2) + pow($y - $py, 2))}]
            if {$distance <= $detection_radius} {
                set found_point 1
                set point_to_remove $point
                break
            }
        }
        
        if {$found_point} {
            # Remove the point visual
            set items [.c find overlapping \
                [expr {[lindex $point_to_remove 0] - $detection_radius}] \
                [expr {[lindex $point_to_remove 1] - $detection_radius}] \
                [expr {[lindex $point_to_remove 0] + $detection_radius}] \
                [expr {[lindex $point_to_remove 1] + $detection_radius}]]
            
            foreach item $items {
                if {[.c type $item] eq "oval" && \
                    [lindex [.c gettags $item] 0] eq "point" && \
                    [string range [lindex [.c gettags $item] 1] 5 end] eq $current_track} {
                    .c delete $item
                    break
                }
            }
            
            # Remove associated connections from both visual and data structure
            foreach key [array names connections] {
                lassign [split $key ","] conn_track x1 y1 x2 y2
                if {$conn_track == $current_track} {
                    if {($x1 == [lindex $point_to_remove 0] && $y1 == [lindex $point_to_remove 1]) || \
                        ($x2 == [lindex $point_to_remove 0] && $y2 == [lindex $point_to_remove 1])} {
                        .c delete $connections($key)
                        unset connections($key)
                    }
                }
            }
            
            # Remove point from data structure
            set idx [lsearch -exact $points($current_track) $point_to_remove]
            if {$idx >= 0} {
                set points($current_track) [lreplace $points($current_track) $idx $idx]
            }
            return 1
        }
    }
    return 0
}

# Modified connection procedure to handle the case
proc connect_points {point1 point2} {
    global connections current_track
    
    # Create unique connection identifier
    set x1 [lindex $point1 0]
    set y1 [lindex $point1 1]
    set x2 [lindex $point2 0]
    set y2 [lindex $point2 1]
    
    # Sort points by x coordinate to ensure consistent connection identification
    if {$x1 > $x2} {
        set temp $point1
        set point1 $point2
        set point2 $temp
        set x1 [lindex $point1 0]
        set y1 [lindex $point1 1]
        set x2 [lindex $point2 0]
        set y2 [lindex $point2 1]
    }
    
    # Create connection key
    set connection_key "$current_track,$x1,$y1,$x2,$y2"
    
    # Check if connection already exists
    if {![info exists connections($connection_key)]} {
        set line_id [.c create line $x1 $y1 $x2 $y2 -fill blue -width 2 -tags "connection connection$current_track"]
        set connections($connection_key) $line_id
        return $line_id
    }
    return {}
}
proc y_to_value {y track} {
    global track_height
    set track_top [expr {$track * $track_height + 10}]
    set track_bottom [expr {($track + 1) * $track_height + 10}]
    set value [expr {100.0 * ($track_bottom - $y) / ($track_bottom - $track_top)}]
    return [expr {max(0.0, min(100.0, $value))}]
}

proc redraw_curve {track} {
    global points
    .c delete curve$track
    if {[info exists points($track)] && [llength $points($track)] >= 2} {
        .c create line {*}[join $points($track)] -fill blue -width 2 -tags curve$track
    }
}

# Dragging procedures
proc start_drag {x y} {
    global dragging drag_item current_track drag_start_x drag_start_y points
    set detection_radius 5
    if {[info exists points($current_track)]} {
        foreach point $points($current_track) {
            set px [lindex $point 0]
            set py [lindex $point 1]
            set distance [expr {sqrt(pow($x - $px, 2) + pow($y - $py, 2))}]
            if {$distance <= $detection_radius} {
                set items [.c find overlapping \
                    [expr {$px - $detection_radius}] \
                    [expr {$py - $detection_radius}] \
                    [expr {$px + $detection_radius}] \
                    [expr {$py + $detection_radius}]]
                foreach item $items {
                    if {[.c type $item] eq "oval" && \
                        [lindex [.c gettags $item] 0] eq "point" && \
                        [string range [lindex [.c gettags $item] 1] 5 end] eq $current_track} {
                        set dragging 1
                        set drag_item $item
                        set drag_start_x $px
                        set drag_start_y $py
                        return 1
                    }
                }
            }
        }
    }
    return 0
}

proc drag_point {x y} {
    global dragging drag_item points current_track timeline_start timeline_end track_height drag_start_x drag_start_y connections
    if {$dragging && $drag_item ne ""} {
        # Constrain x coordinate to timeline bounds
        set x [expr {max($timeline_start, min($timeline_end, $x))}]
        
        # Constrain y coordinate to track bounds
        set track_top [expr {$current_track * $track_height + 10}]
        set track_bottom [expr {($current_track + 1) * $track_height + 10}]
        set y [expr {max($track_top, min($track_bottom, $y))}]
        
        .c coords $drag_item [expr {$x-3}] [expr {$y-3}] [expr {$x+3}] [expr {$y+3}]
        
        # Update point position in data structure and update affected connections
        if {[info exists points($current_track)]} {
            set idx [lsearch -exact $points($current_track) [list $drag_start_x $drag_start_y]]
            if {$idx >= 0} {
                # Update connections before updating the point position
                foreach key [array names connections] {
                    lassign [split $key ","] conn_track x1 y1 x2 y2
                    if {$conn_track == $current_track} {
                        set line_id $connections($key)
                        if {$x1 == $drag_start_x && $y1 == $drag_start_y} {
                            # Update start point of line
                            .c coords $line_id $x $y $x2 $y2
                            # Create new key and update connections array
                            unset connections($key)
                            set new_key "$current_track,$x,$y,$x2,$y2"
                            set connections($new_key) $line_id
                        } elseif {$x2 == $drag_start_x && $y2 == $drag_start_y} {
                            # Update end point of line
                            .c coords $line_id $x1 $y1 $x $y
                            # Create new key and update connections array
                            unset connections($key)
                            set new_key "$current_track,$x1,$y1,$x,$y"
                            set connections($new_key) $line_id
                        }
                    }
                }
                
                # Update point position in data structure
                set points($current_track) [lreplace $points($current_track) $idx $idx [list $x $y]]
                set points($current_track) [lsort -index 0 -real $points($current_track)]
                set drag_start_x $x
                set drag_start_y $y
            }
        }
        
        set value [y_to_value $y $current_track]
        .controls.values configure -text "Value: [format %.1f $value]"
    }
}

proc end_drag {} {
    global dragging drag_item
    set dragging 0
    set drag_item {}
}

bind .c <Button-1> {
    if {%x >= $timeline_start && %x <= $timeline_end} {
        set track_y [expr {int((%y - 10) / $track_height)}]
        if {$track_y >= 0 && $track_y < $tracks} {
            set current_track $track_y
            if {![start_drag %x %y]} {
                add_point %x %y
            }
        }
    }
}

bind .c <Shift-Button-1> {
    if {%x >= $timeline_start && %x <= $timeline_end} {
        set track_y [expr {int((%y - 10) / $track_height)}]
        if {$track_y >= 0 && $track_y < $tracks} {
            set current_track $track_y
            if {[llength $points($current_track)] > 0} {
                set new_point [list %x %y]
                set nearest [find_nearest_point %x %y]
                if {$nearest ne ""} {
                    add_point %x %y
                    connect_points $new_point $nearest
                }
            }
        }
    }
}


bind .c <Control-Button-1> {
    if {%x >= $timeline_start && %x <= $timeline_end} {
        set track_y [expr {int((%y - 10) / $track_height)}]
        if {$track_y >= 0 && $track_y < $tracks} {
            set current_track $track_y
            remove_point %x %y
        }
    }
}

bind .c <B1-Motion> {
    drag_point %x %y
}

bind .c <ButtonRelease-1> {
    end_drag
}

# Initialize
setup_pd_connection

# Cleanup procedure
proc cleanup {} {
    global pd_channel
    if {$pd_channel ne ""} {
        close $pd_channel
    }
}

# Bind cleanup to window close event
bind . <Destroy> cleanup

# Draw initial timeline grid
for {set i 0} {$i <= $tracks} {incr i} {
    set y [expr {$i * $track_height + 10}]
    .c create line $timeline_start $y $timeline_end $y -fill gray
}

.c create line $timeline_start 10 $timeline_start [expr {$tracks * $track_height + 10}] -fill black -width 2
.c create line $timeline_end 10 $timeline_end [expr {$tracks * $track_height + 10}] -fill black -width 2

# Draw timeline ticks
draw_timeline_ticks

##################################################################
#                     Saving                                     #
##################################################################

## Modified save_points procedure to include connections
proc save_points {filename} {
    global points tracks connections
    set f [open $filename w]
    puts $f $tracks
    
    # Save points
    for {set track 0} {$track < $tracks} {incr track} {
        if {[info exists points($track)]} {
            puts $f [llength $points($track)]
            foreach point $points($track) {
                puts $f "$track [lindex $point 0] [lindex $point 1]"
            }
        } else {
            puts $f 0
        }
    }
    
    # Save connections
    puts $f [array size connections]
    foreach {key value} [array get connections] {
        puts $f $key
    }
    
    close $f
}

# Modified load_points procedure to include connections
proc load_points {filename} {
    global points tracks current_track connections
    set f [open $filename r]
    
    # Clear existing points and connections
    foreach track_points [array names points] {
        unset points($track_points)
        .c delete point$track_points
    }
    foreach connection [array names connections] {
        .c delete $connections($connection)
        unset connections($connection)
    }
    
    # Read number of tracks
    set file_tracks [gets $f]
    
    # Read points
    for {set track 0} {$track < $file_tracks} {incr track} {
        set num_points [gets $f]
        if {$num_points > 0} {
            for {set i 0} {$i < $num_points} {incr i} {
                set point_data [gets $f]
                lassign $point_data saved_track x y
                set current_track $saved_track
                add_point $x $y
            }
        }
    }
    
    # Read connections
    set num_connections [gets $f]
    for {set i 0} {$i < $num_connections} {incr i} {
        set connection_key [gets $f]
        lassign [split $connection_key ","] track x1 y1 x2 y2
        set point1 [list $x1 $y1]
        set point2 [list $x2 $y2]
        set current_track $track
        connect_points $point1 $point2
    }
    
    close $f
    .c delete ticks
    draw_timeline_ticks
}

# These are the button definitions - same as before
frame .controls.file
pack .controls.file -side right -padx 10

button .controls.file.save -text "Save" -command {
    set filename [tk_getSaveFile -defaultextension ".txt" \
                                -filetypes {{"Text Files" ".txt"} {"All Files" "*"}}]
    if {$filename ne ""} {
        save_points $filename
    }
}

button .controls.file.load -text "Load" -command {
    set filename [tk_getOpenFile -defaultextension ".txt" \
                                -filetypes {{"Text Files" ".txt"} {"All Files" "*"}}]
    if {$filename ne ""} {
        load_points $filename
    }
}

pack .controls.file.save .controls.file.load -side left -padx 2