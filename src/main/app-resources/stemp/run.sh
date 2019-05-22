#!/bin/bash

source /application/libexec/functions.sh

export LM_LICENSE_FILE=1700@idl.terradue.com
export STEMP_BIN=/opt/STEMP-S2/bin
#export STEMP_BIN=/data/code/code_S2
export IDL_BIN=/usr/local/bin
export PROCESSING_HOME=${TMPDIR}/PROCESSING
export GDAL_DATA=/opt/anaconda/share/gdal

function main() {

  local ref=$1
  local identifier=$(opensearch-client "${ref}" identifier)
  local mission="Sentinel2"
  local date=$(opensearch-client "${ref}" enddate)

  ciop-log "INFO" "**** STEMP node ****"
  ciop-log "INFO" "------------------------------------------------------------"
  ciop-log "INFO" "Mission: ${mission}"
  ciop-log "INFO" "Input product reference: ${ref}"
  ciop-log "INFO" "------------------------------------------------------------"

  ciop-log "INFO" "STEMP environment setup"
  ciop-log "INFO" "------------------------------------------------------------"
  export PROCESSING_HOME=${TMPDIR}/PROCESSING
  mkdir -p ${PROCESSING_HOME}
  ciop-log "INFO" "STEMP environment setup finished"
  ciop-log "INFO" "------------------------------------------------------------"

  ciop-log "INFO" "Downloading input product"
  ciop-log "INFO" "------------------------------------------------------------"
  if [ ${LOCAL_DATA} == "true" ]; then
    ciop-log "INFO" "Getting local input product"
    product=$( ciop-copy -f -U -O ${PROCESSING_HOME} /data/SCIHUB/${identifier}.zip)
  else  
    ciop-log "INFO" "Getting remote input product"
    product=$( getData "${ref}" "${PROCESSING_HOME}" ) || return ${ERR_GET_DATA}
  fi
  
  ciop-log "INFO" "Input product downloaded"
  ciop-log "INFO" "------------------------------------------------------------"

  ciop-log "INFO" "Uncompressing product"
  ciop-log "INFO" "------------------------------------------------------------"
  unzip -qq -o -j ${product} */GRANULE/*/IMG_DATA/*B04.jp2 */GRANULE/*/IMG_DATA/*B8A.jp2 */GRANULE/*/IMG_DATA/*B11.jp2 */GRANULE/*/IMG_DATA/*B12.jp2 -d ${PROCESSING_HOME} 
  res=$?
  [ ${res} -ne 0 ] && return ${$ERR_UNCOMP}
  ciop-log "INFO" "Product uncompressed"
  ciop-log "INFO" "------------------------------------------------------------"

  ciop-log "INFO" "Converting jp2 to tiff"
  ciop-log "INFO" "------------------------------------------------------------"
  
  for granule_band in $( ls ${PROCESSING_HOME}/*.jp2 ); do
      granule_band_identifier=$( basename ${granule_band})
      granule_band_identifier=${granule_band_identifier%.jp2}
      gdalinfo ${granule_band} 

      gdal_translate ${granule_band} ${PROCESSING_HOME}/${granule_band_identifier}.tmp
     # force to the 20m resolution
      gdalwarp -tr 20 20 ${PROCESSING_HOME}/${granule_band_identifier}.tmp ${PROCESSING_HOME}/${granule_band_identifier}.tif
  done
  
  ciop-log "INFO" "Product uncompressed"
  ciop-log "INFO" "------------------------------------------------------------"

  ciop-log "INFO" "Preparing file_input.cfg"
  ciop-log "INFO" "------------------------------------------------------------"
  
  for granule_band_04 in $( ls ${PROCESSING_HOME}/*B04.tif ); do
      # TODO: we should get the value in a different way
    # Converting B04 from 10m to 20m resolution
    mv ${granule_band_04} ${granule_band_04}.tmp
    gdalwarp -tr 20 20 ${granule_band_04}.tmp ${granule_band_04}
      echo ${granule_band_04}
  done
  
  leng=${#granule_band_04}
  echo "$(basename ${granule_band_04:0:leng-8})_B8A.tif" >> ${PROCESSING_HOME}/file_input.cfg
  echo "$(basename ${granule_band_04:0:leng-8})_B11.tif" >> ${PROCESSING_HOME}/file_input.cfg
  echo "$(basename ${granule_band_04:0:leng-8})_B12.tif" >> ${PROCESSING_HOME}/file_input.cfg
  echo "$(basename ${granule_band_04})" >> ${PROCESSING_HOME}/file_input.cfg

  ciop-log "INFO" "file_input.cfg content:"
  cat ${PROCESSING_HOME}/file_input.cfg 1>&2
  ciop-log "INFO" "------------------------------------------------------------"

  ciop-log "INFO" "PROCESSING_HOME content:"
  ciop-log "INFO" "------------------------------------------------------------"
  ls -l ${PROCESSING_HOME} 1>&2
  ciop-log "INFO" "------------------------------------------------------------"

  if [ "${DEBUG}" = "true" ]; then
  #  ciop-publish -m ${PROCESSING_HOME}/*.TIF || return $?
    ciop-publish -m ${PROCESSING_HOME}/*.tif || return $?
  fi

  ciop-log "INFO" "Starting STEMP core"
  ciop-log "INFO" "------------------------------------------------------------"
  cd ${PROCESSING_HOME}
  cp ${STEMP_BIN}/STEMP_S2.sav .
  ${IDL_BIN}/idl -rt=STEMP_S2.sav -IDL_DEVICE Z

  ciop-log "INFO" "STEMP core finished"
  ciop-log "INFO" "------------------------------------------------------------"

  ciop-log "INFO" "Generating quicklooks"
  ciop-log "INFO" "------------------------------------------------------------"
  cd ${PROCESSING_HOME}
  ls ${PROCESSING_HOME}
  string_inp=$(head -n 1 file_input.cfg)
  leng=${#string_inp}
  ciop-log "INFO   ${PROCESSING_HOME}/${string_inp:0:leng-8}_HOT_SPOT.tif" 
  generateQuicklook ${string_inp:0:leng-8}_HOT_SPOT.tif ${PROCESSING_HOME}

  ciop-log "INFO" "Quicklooks generated:"
  ls -l ${PROCESSING_HOME}/*HOT_SPOT*.rgb* 1>&2
  ciop-log "INFO" "------------------------------------------------------------"
  
  ciop-log "INFO" "Preparing metadata file"
  ciop-log "INFO" "------------------------------------------------------------"
  METAFILE=${PROCESSING_HOME}/${string_inp:0:leng-8}_HOT_SPOT.tif.properties

  echo "title=STEMP - HOT-SPOT detection - ${date}" >> ${METAFILE}
  echo "date=${date}" >> ${METAFILE}
  echo "Input\ product=${identifier}" >> ${METAFILE}
  echo "Input\ product\ tile=$( echo ${identifier} | cut -d '_' -f 6)" >> ${METAFILE}
  # Resolution is fixed to 20m because:
  # - Bands B8A, B11 and B12 have already 20m resolution (https://earth.esa.int/web/sentinel/user-guides/sentinel-2-msi/resolutions/spatial)
  # - Band B04 is converted to 20m
  echo "Resolution=20m" >> ${METAFILE}
  echo "Producer=INGV"  >> ${METAFILE}
  echo "Service\ name=STEMP-S2 Full"  >> ${METAFILE}
  echo "Service\ version=1.2.1"  >> ${METAFILE}
  echo "HOT\ SPOT=Hot pixels(red),very hot pixels(yellow)"  >> ${METAFILE}
  
  ciop-log "INFO" "Metadata file content:"
  cat ${PROCESSING_HOME}/${string_inp:0:leng-8}_HOT_SPOT.tif.properties 1>&2
  ciop-log "INFO" "------------------------------------------------------------"

  ciop-log "INFO" "Compressing results using LZW compression algorithm"
  ciop-log "INFO" "------------------------------------------------------------"
  
  suffix=".lzw.compressed"
  find ${PROCESSING_HOME} -name "*_HOT_SPOT*.tif" -exec gdal_translate -of GTiff -co "COMPRESS=LZW" -co "TILED=YES" {} {}${suffix} \;
  find ${PROCESSING_HOME} -type f -name "*${suffix}" | while read f; do mv "$f" "${f%${suffix}}"; done
 
  ciop-log "INFO" "Results compressed"
  ciop-log "INFO" "------------------------------------------------------------"
  
  ciop-log "INFO" "Staging-out results"
  ciop-log "INFO" "------------------------------------------------------------"
  ciop-publish -m ${PROCESSING_HOME}/*HOT_SPOT*.tif || return $?
  ciop-publish -m ${METAFILE} || return $?
  [ ${res} -ne 0 ] && return ${ERR_PUBLISH}

  ciop-log "INFO" "Results staged out"
  ciop-log "INFO" "------------------------------------------------------------"

  ciop-log "INFO" "Cleaning up PROCESSING_HOME"
  rm -rf ${PROCESSING_HOME}/*
  ciop-log "INFO" "------------------------------------------------------------"
  ciop-log "INFO" "**** STEMP node finished ****"
}

while read ref
do
    main "${ref}" || exit $?
done

exit ${SUCCESS}
