#!/usr/bin/env bash

# todo: flag to extract a album art cover from one of any file, and use that as a cover. 
# or some sort of combination to use last valid album art using a set tmp file

# todo: metadata add track number. make compatible with "NA" null value
# todo: test for failures
# todo: add argument to allow skipping of yt-dlp and reprocessing working-dir
# todo: check for conversion success before deleting?
# todo: check for filecount at end?
# todo: progress counter for for-loop

# +-------------------------------------------------------------------------+ #
# |                              Documentation                              | #
# +-------------------------------------------------------------------------+ #

#                                 dependencies                                #
# 
# yt-dlp: Downloading songs from youtube
# ffmpeg: For transcoding down to 64kbps opus, yt-dlp also uses it
# ffprobe: Usually comes with ffmpeg. used to analyze cover image filetype.
#          Might be able to remove dep.
# image-magick: For manipulating and compressing the cover image
# kid3-cli: For adding a cover image to the final opus file

#                                 yt-dlp args                                 #
#
# --format: Prefer Opus '250' first (64kbps), then fallback to whatever is best, 
# with video last
# --no-playlist: is ignored when the URL is only a playlist. This is for when
# a url is a song+playlist url in one. This gives me the option to download
# single tracks without further intervention
# --extract-audio: only runs when video is the last resort
# --audio-format: we desire opus. Skips transcoding when already opus
# --add-metadata: attempts to fill out the id3 tags appropriately
# --embed-thumbnail: the thumbnails for music are square, but yt-dlp graps 
# widescreen which is unideal.

#                                 ffmpeg args                                 #
# 
# -y: automatically say yes to existing file override
# -v: ffmpeg is too noisy. only errors
# -i: input
# -an: no audio in output
# -vcodec: copy the image metadata

# +-------------------------------------------------------------------------+ #
# |                             Initialization                              | #
# +-------------------------------------------------------------------------+ #

COLOR_RESET="\033[0m"
COLOR_YELLOW="\033[33m"
COLOR_YELLOW_BRIGHT="\033[93m"
COLOR_MAGENTA_BRIGHT="\033[95m"
COLOR_RED_BRIGHT="\033[91m"

WORKING_DIR="$HOME/Downloads/_yt-dlp"
DOWNLOAD_DIR="$HOME/Downloads/yt-dlp"
YTDL=$(command -v yt-dlp || command -v youtube-dl)
error_tracker=()

# --- Dependency Check --- #
check_dependencies() {
  local DEPS=($YTDL ffmpeg ffprobe magick kid3-cli) # List of required commands
  local is_missing_deps=0 # Flag for missing deps

  for cmd in "${DEPS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Error: $cmd is not installed."
      is_missing_deps=1
    fi
  done

  # Quit if anything is missing
  if [ "$is_missing_deps" -eq 1 ]; then
    exit 1
  fi
}

# --- Setup --- #
check_dependencies
mkdir -p "$WORKING_DIR"
mkdir -p "$DOWNLOAD_DIR"
cd $WORKING_DIR


# +-------------------------------------------------------------------------+ #
# |                          Bash Args Boilerplate                          | #
# +-------------------------------------------------------------------------+ #

POSITIONAL_ARGS=()
BITRATE="64k"
SKIP_YTDL=NO
VERBOSE=""
SKIP_ALBUM_ART=NO # Using "NO" for increased readability in if-statements
IS_COLLECTION=""

show_help() {
  cat <<EOF
Usage: ytdl-music [flags] url

Passing no arguments enters an interactive mode in which to paste a youtube url

Options:
  -h,  --help        Show this help and exit
  -v,  --verbose     Enable verbose mode
  -s,  --skip-ytdl   Skip yt-dl and only process existing files in the working_dir
                     (helpful for stuck files, or processing existing collections)
  -sa, --skip-album-art
                     Bypass processing album-art covers (extracting, cropping,
                     injecting)
  --collections      Specifies that the files in the working_dir are not from one
                     single album. Useful for processing collections at a time.
                     Prevents borrowing album-covers from other files.

Requirements:
  - yt-dl (or yt-dlp)
  - ffmpeg
  - ffprobe
  - image-magick
  - kid3-cli
EOF
}

# Boilerplate Arg management https://stackoverflow.com/questions/192249/how-do-i-parse-command-line-arguments-in-bash
# flags that take no values only perform one shift, instead of two
while [[ $# -gt 0 ]]; do
  case $1 in
    -s|--skip-ytdl)
      SKIP_YTDL=YES
      shift # past argument
      ;;
    -b|--bitrate)
      BITRATE="$2"
      shift # past argument
      shift # past value
      ;;
    -sa|--skip-album-art)
      SKIP_ALBUM_ART=YES
      shift # past argument
      ;;
    --collections)
      IS_COLLECTION=YES
      shift # past argument
      ;;
    --help)
      show_help
      shift # past argument
      exit 0
      ;;
    -v|--verbose)
      # todo
      VERBOSE=YES
      shift # past argument
      ;;
    -*|--*)
      echo "Unknown option $1"
      exit 1
      ;;
    *)
      POSITIONAL_ARGS+=("$1") # save positional arg
      shift # past argument
      ;;
  esac
done

set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

# Assign last argument as url
if [[ -n $1 ]]; then
    # echo "Last line of file specified as non-opt/last argument:"
    url="$1"
fi

# If no args passed in, interactively ask for the URL
if [ -z "$1" ] && [ "$SKIP_YTDL" = "NO" ]; then
  read -p "Enter the YT/YT-Music URL: " url
else
  url="$1"
fi


# +-------------------------------------------------------------------------+ #
# |                                  Utils                                  | #
# +-------------------------------------------------------------------------+ #

# Print to terminal (uses stderr so functions can leverage echo's stdout for return values)
print() {
    echo -e "$@" >&2
}

print_verbose() {
  if [ "$VERBOSE" != "YES" ]; then return; fi
  echo -e "$COLOR_MAGENTA_BRIGHT""$@""$COLOR_RESET" >&2
}

# A nicely printed report at the end
error_report() {
  if [ "${#error_tracker[@]}" -gt 0 ]; then
    print "\n$COLOR_RED_BRIGHT""There were ${#error_tracker[@]} error(s):"
  fi

  for item in "${error_tracker[@]}"; do
    print "  - $COLOR_RED_BRIGHT""$item"
  done
}

cleanup() {
  local move_src="$1" # $filepath_transcoded_tmp
  local move_dst="$2" # $filepath_final_out
  local albumart_extracted="$3" # $albumart_extracted_filename
  local albumart_cropped="$4" # $albumart_cropped_filename

  # move (clobber) file into final destination
  # remove temp files (attempt regardless if files were made this session)
  # todo: remove now-old opus assuming it's conversion was successful
  echo -e "$COLOR_YELLOW_BRIGHT""  Cleanup""$COLOR_RESET"
  print_verbose "  mv\n    src: $move_src\n    dst: $move_dst"

  mv "$move_src" "$move_dst"
  rm -f "$albumart_extracted"
  rm -f "$albumart_cropped"
}

# +-------------------------------------------------------------------------+ #
# |                                Download                                 | #
# +-------------------------------------------------------------------------+ #

# Note: ffmpeg does not keep cover images through opus conversions, so we must
#       dump and inject it into the final file. Incidentally, yt-dlp seems to
#       Download widescreen cover images, which are incorrect. So we use
#       imagemagick to crop and downscale.

download_music() {
  local yt_url="$1" # $url

  if [ "$SKIP_YTDL" = "YES" ]; then
    print "$COLOR_YELLOW_BRIGHT""Step: Skipping yt-dlp""$COLOR_RESET""\n"
    return 0
  fi
  
  # Note: ytdl quality selectors don't seem to apply in our configuration
  print "$COLOR_YELLOW_BRIGHT""Step: Running yt-dlp""$COLOR_RESET""\n"
  # todo: swap out for the universal path for yt-dl/p
  yt-dlp \
    --format "250/bestaudio[ext=opus]/bestaudio/best" \
    --extract-audio \
    --audio-format opus \
    --add-metadata \
    --embed-thumbnail \
    --no-playlist \
    --output "%(artist)s -- %(album)s -- %(0Dtrack_number,playlist_index)s -- %(title)s.%(ext)s" \
    $yt_url

  # Abort and exit script if yt-dl fails. If the user wants to process existing files, they can
  # run the skip flag manually
  if [ $? -ne 0 ]; then
    print "$COLOR_RED_BRIGHT""Aborted early, as yt-dl failed. Rerun with -s|--skip-ytdl to process existing files in the working_dir"
    exit 1
  fi
}

# +-------------------------------------------------------------------------+ #
# |                              Album Covers                               | #
# +-------------------------------------------------------------------------+ #

probe_album_cover_ext() {
  local FALLBACK_EXT="jpg"

  # Guard
  if [ "$SKIP_ALBUM_ART" = "YES" ]; then
    print "Skipping Album Cover Routines"
    echo $FALLBACK_EXT # return for graceful handling
    return 0
  fi

  # Probe for file extension
  albumart_ext=$(
    ffprobe \
      -v error \
      -select_streams v:0 \
      -show_entries stream=codec_name \
      -of default=noprint_wrappers=1:nokey=1 \
      "$1"
  )
  
  # Debug msg for failure
  if [ -z "$albumart_ext" ]; then
    print_verbose "  Unable to probe Album Art Extension. fallback is $FALLBACK_EXT"
  fi

  # Fallback
  albumart_ext=${albumart_ext:-$FALLBACK_EXT}

  # Return
  print_verbose "  Album Art Extension set to: $albumart_ext"
  echo "$albumart_ext"
}

extract_album_cover() {
  local input_file="$1" # $filename
  local output_file="$2" # $albumart_extracted_filename
  local fallback_file="$3" # $albumart_universal_album_filename

  # Note: this is written for .opus specifically. flacs and other formats may fail
  # todo: "${VERBOSE:+info}${VERBOSE:+"error"}" for -v line
  if [ "$SKIP_ALBUM_ART" = "YES" ]; then
    print_verbose "Skipping: Extract Album Cover"
    return 0
  fi

  print "$COLOR_YELLOW_BRIGHT""  Extract Album Art""$COLOR_RESET"

  ffmpeg \
    -y \
    -v error \
    -i "$input_file" \
    -an \
    -vcodec copy \
    "$output_file" \
    >/dev/null 2>&1 # silence ffmpeg

  # Check for Failure
  if [ $? -ne 0 ]; then
    echo -e "  $COLOR_RED_BRIGHT""ffmpeg failed to extract album art""$COLOR_RESET"

    # Now check for album-wide cover already exists. If so, copy it into place
    if [ -f "$fallback_file" ]; then
      echo -e "  $COLOR_YELLOW""Using album-wide cover as alternative"
      cp "$fallback_file" "$output_file"
    fi
  fi
}

# --- Crop Cover Image ---
# crop_album_cover <input> <output>
# Arguments
#   input   – filename of the input image
#   output  – filename of the output (cropped) image
crop_album_cover() {
  local input="$1" # $albumart_extracted_filename
  local output="$2" # $albumart_cropped_filename

  if [ "$SKIP_ALBUM_ART" = "YES" ]; then
    print_verbose "Skipping: Crop Album Cover"
    return 0
  fi

  print "$COLOR_YELLOW_BRIGHT""  Crop Album Art""$COLOR_RESET"
  img_size=$(magick identify -format '%[fx:min(w,h)]' "$input")

  # Failure handling
  if [ $? -ne 0 ]; then
    print "  $COLOR_RED_BRIGHT""image-magick failed to determine image size""$COLOR_RESET"
    return 1
  fi

  magick \
    "$input" \
    -gravity center \
    -crop "${img_size}x${img_size}+0+0" \
    +repage \
    -resize 512x512 \
    "$output"
}

set_universal_cover_fallback() {
  local cover="$1"
  local universal_cover="$2" # $albumart_universal_album_filename

  if [ "$IS_COLLECTION" = "YES" ]; then
    return 0
  fi

  if [ -f "$cover" ]; then
    print_verbose "  Setting Universal Album Art Fallback"
    cp "$cover" "$universal_cover"
  fi
}

set_album_cover() {
  local cover="$1" # $albumart_cropped_filename
  local output="$2" # $filepath_transcoded_tmp
  local fallback="$3" # $albumart_universal_album_filename

  # Setting cover-art for opus is notoriously difficult. kid3-cli works, ffmpeg
  # works too, but only if image is already in spec format for passin as custom
  # metadata argument.
  # 
  # Note: The fallback cover is set through a cp command (if conditions apply)
  #       before this function runs
  # 
  # BUG: when specifying a cover, current directory does not matter! The image
  #      must be in the same directory as the file being modified
  if [ "$SKIP_ALBUM_ART" = "YES" ]; then
    print_verbose "Skipping: Set Album Cover"
    return 0
  fi

  echo -e "$COLOR_YELLOW_BRIGHT""  Set Album Art""$COLOR_RESET"
  kid3-cli \
    -c "set picture:${cover} 'Cover (front)'" \
    "$output"

  if [ $? -ne 0 ]; then
    print "  $COLOR_RED_BRIGHT""set-cover error in kid3-cli""$COLOR_RESET"
    error_tracker+=("kid3-cli errored on set-cover for: $input")
  fi
}

# +-------------------------------------------------------------------------+ #
# |                               Transcoding                               | #
# +-------------------------------------------------------------------------+ #

transcode_audio() {
  local input="$1" # $filename
  local output="$2" # $filepath_transcoded_tmp

  print "$COLOR_YELLOW_BRIGHT""  Transcode to $BITRATE Opus""$COLOR_RESET"

  ffmpeg \
    -y \
    -v error \
    -i "$input" \
    -c:a libopus \
    -b:a "$BITRATE" \
    -map_metadata 0 \
    "$output"

  if [ $? -ne 0 ]; then
    print "  $COLOR_RED_BRIGHT""transcode error""$COLOR_RESET"
    error_tracker+=("re-transcode to opus failed on: $input")
  fi
}

# +-------------------------------------------------------------------------+ #
# |                                   Main                                  | #
# +-------------------------------------------------------------------------+ #

# Immediately Print Some Information
print_verbose ""
print_verbose "yt-dl/p location: $YTDL"
print_verbose "Positional Arguments: $POSITIONAL_ARGS"
print_verbose "Bitrate: $BITRATE"
print_verbose "Skip yt-dl step?: $SKIP_YTDL"
print_verbose "Skip Album Art Management?: $SKIP_ALBUM_ART"
print_verbose ""

# --- Download Music --- #
download_music $url

# --- Iterate over files in working directory --- #
echo -e "$COLOR_YELLOW_BRIGHT""Step: Downsample All to $BITRATE Opus""$COLOR_RESET""\n"

shopt -s nullglob # dont expand unmatched globs
for filename in *.opus *.mp3 *.flac; do
  print "$COLOR_YELLOW_BRIGHT""File: ""$COLOR_YELLOW""$filename""$COLOR_RESET"

  basename="${file%.*}"  # removes everything after the last dot
  filepath_final_out="$DOWNLOAD_DIR/${basename}.opus"
  filepath_transcoded_tmp="$WORKING_DIR/${basename}.tmp.opus"
  albumart_ext="$(probe_album_cover_ext "$filename")" # Probe Album Cover for Extension
  albumart_extracted_filename="cover.tmp.$albumart_ext"
  albumart_cropped_filename="cover.jpg"
  albumart_universal_album_filename="album.jpg"

  extract_album_cover \
    "$filename" \
    "$albumart_extracted_filename" \
    "$albumart_universal_album_filename"

  crop_album_cover \
    "$albumart_extracted_filename" \
    "$albumart_cropped_filename"

  set_universal_cover_fallback \
    "$albumart_cropped_filename" \
    "$albumart_universal_album_filename"
  
  transcode_audio \
    "$filename" \
    "$filepath_transcoded_tmp"

  set_album_cover \
    "$albumart_cropped_filename" \
    "$filepath_transcoded_tmp" \
    "$albumart_universal_album_filename"
  
  cleanup \
    "$filepath_transcoded_tmp" \
    "$filepath_final_out" \
    "$albumart_extracted_filename" \
    "$albumart_cropped_filename"

done
shopt -u nullglob # see matching shopt above

# --- Final Cleanup --- #
# rm -f "$albumart_universal_album_filename"
echo -e "$COLOR_YELLOW_BRIGHT""Process Complete""$COLOR_RESET"
error_report
