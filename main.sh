#!/usr/bin/env bash

# todo: metadata add track number. make compatible with "NA" null value
# todo: test for failures
# todo: add argument to allow skipping of yt-dlp and reprocessing working-dir
# todo: check for conversion success before deleting?
# todo: check for filecount at end?
# todo: progress counter for for-loop
# 
# ex: https://music.youtube.com/playlist\?list\=OLAK5uy_kvrD-dFZ-EwB4GY8qfKLGzekTbheTkHlE

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
# |                          Bash Args Boilerplate                          | #
# +-------------------------------------------------------------------------+ #

show_help() {
  cat <<EOF
Usage: ytdl-music [flags] url

Passing no arguments enters an interactive mode in which to paste a youtube url

Options:
  -h, --help        Show this help and exit
  -v, --verbose     Enable verbose mode
  -s, --skip-ytdl   Skip yt-dl and only process existing files in the working_dir
                    (helpful for stuck files, or processing existing collections)

Requirements:
  - yt-dl (or yt-dlp)
  - ffmpeg
  - ffprobe
  - image-magick
  - kid3-cli
EOF
}

POSITIONAL_ARGS=()
BITRATE="64k"
SKIP_YTDL=NO
VERBOSE=NO

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

# Debug Printing
if [ "$VERBOSE" = "YES" ]; then
  echo "Parameters Specified:"
  echo ""
  echo "Positional Arguments: $POSITIONAL_ARGS"
  echo "Bitrate: $BITRATE"
  echo "Skip yt-dl step?: $SKIP_YTDL"
  echo ""
fi

# echo -e "\033[94mBright Blue\033[0m"



# +-------------------------------------------------------------------------+ #
# |                             Initialization                              | #
# +-------------------------------------------------------------------------+ #

COLOR_RESET="\033[0m"
COLOR_YELLOW="\033[33m"
COLOR_YELLOW_BRIGHT="\033[93m"

WORKING_DIR="$HOME/Downloads/_yt-dlp"
DOWNLOAD_DIR="$HOME/Downloads/yt-dlp"

YTDL=$(command -v yt-dlp || command -v youtube-dl)
DEPS=($YTDL ffmpeg ffprobe magick kid3-cli) # List of required commands
MISSING=0 # Flag for missing deps

# Check each of the deps before quitting on failure
for cmd in "${DEPS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: $cmd is not installed."
    MISSING=1
  fi
done

# Quit if anything is missing
if [ "$MISSING" -eq 1 ]; then
  exit 1
fi

mkdir -p "$WORKING_DIR"
mkdir -p "$DOWNLOAD_DIR"
cd $WORKING_DIR




# +-------------------------------------------------------------------------+ #
# |                             Download Music                              | #
# +-------------------------------------------------------------------------+ #

exit 0

# Note: quality selectors don't seem to apply in our configuration
echo -e "$COLOR_YELLOW_BRIGHT----- Running yt-dlp -----$COLOR_RESET"
# yt-dlp \
#   --format "250/bestaudio[ext=opus]/bestaudio/best" \
#   --extract-audio \
#   --audio-format opus \
#   --add-metadata \
#   --embed-thumbnail \
#   --no-playlist \
#   --output "%(artist)s -- %(album)s -- %(0Dtrack_number,playlist_index)s -- %(title)s.%(ext)s" \
#   $url

# +-------------------------------------------------------------------------+ #
# |                        Process Downloaded Files                         | #
# +-------------------------------------------------------------------------+ #

echo -e "$COLOR_YELLOW_BRIGHT----- Downsample All to 64k Opus -----$COLOR_RESET"

# for file in *.opus; do

shopt -s nullglob # dont expand unmatched globs
for file in *.opus *.mp3 *.flac; do
  # ffmpeg does not keep cover images through conversions, so we must dump
  # and inject it into the final file. Incidentally, yt-dlp seems to Download
  # widescreen cover images, which are incorrect. So we use imagemagick to fix
  # and set downscale size while we are at it
  echo -e "$COLOR_YELLOW_BRIGHT""File: ""$COLOR_YELLOW""$file""$COLOR_RESET"

  # Note: using static filepaths for cover/tmp files to simplify the pass-ins 
  # for subsequent commands.
  out_filepath="$DOWNLOAD_DIR/${file}"
  tmp_filepath="$WORKING_DIR/${file}.tmp.opus"
  albumart_ext=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$file")
  albumart_ext=${albumart_ext:-jpg}
  albumart_filename="cover.jpg"
  albumart_tmp_filename="cover.tmp.$albumart_ext"

  echo "albumart_ext $albumart_ext"
  # albumart_filename="$file.jpg"
  # albumart_tmp_filename="$file.tmp.$albumart_ext"

  # --- Extract Cover Image --- #
  # Note: this is written for .opus specifically. flacs and other formats may fail
  echo -e "$COLOR_YELLOW_BRIGHT""  Extract Album Art"
  ffmpeg \
    -y \
    -v error \
    -i "$file" \
    -an \
    -vcodec copy \
    "$albumart_tmp_filename"

  # --- Crop Cover Image --- #
  echo -e "$COLOR_YELLOW_BRIGHT""  Crop Album Art""$COLOR_RESET"
  img_size=$(magick identify -format '%[fx:min(w,h)]' "$albumart_tmp_filename")
  magick \
    "$albumart_tmp_filename" \
    -gravity center \
    -crop "${img_size}x${img_size}+0+0" \
    +repage \
    -resize 512x512 \
    "$albumart_filename"
  
  # --- Resample Opus --- #
  echo -e "$COLOR_YELLOW_BRIGHT""  Resample to 64k Opus""$COLOR_RESET"
  ffmpeg \
    -y \
    -v error \
    -i "$file" \
    -c:a libopus \
    -b:a "$BITRATE" \
    -map_metadata 0 \
    "$tmp_filepath"

  # --- Set Cover Art --- #
  # Setting cover-art for opus is notoriously difficult. kid3-cli works, ffmpeg
  # works too, but only if image is already in spec format for passin as custom
  # metadata argument.
  # 
  # BUG: when specifying a cover, current directory does not matter! The image
  # must be in the same directory as the file being modified
  echo -e "$COLOR_YELLOW_BRIGHT""  Set Album Art""$COLOR_RESET"
  kid3-cli -c "set picture:${albumart_filename} 'Cover (front)'" "$tmp_filepath"

  # --- Cleanup --- #
  # move (clobber) file into final destination
  # remove temp files
  # remove now-old opus assuming it's conversion was successful
  echo -e "$COLOR_YELLOW_BRIGHT""  Cleanup""$COLOR_RESET"
  mv "$tmp_filepath" "$out_filepath"
  # rm -f "$albumart_tmp_filename"
  # rm -f "$albumart_filename"
  echo ""
done
shopt -u nullglob # see matching shopt above

echo -e "$COLOR_YELLOW_BRIGHT----- Finished -----$COLOR_RESET"
