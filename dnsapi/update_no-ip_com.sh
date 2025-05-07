#!/usr/bin/env sh
#
# script for sending updates to https://dynupdate.no-ip.com, https://dynupdate6.no-ip.com
# 2025 Ken <qingzi dot zhang at outlook dot com>
# API documentation at https://developer.noip.com/guides/
#
# This script is called by ddnss.sh inside handle_record() function
# https://github.com/qingzi-zhang/ddnss.sh

update_uri4="dynupdate.noip.com"
update_uri6="dynupdate6.noip.com"

main() {
  # Determine the update URI based on the record type
  if [ "${record_type}" = "AAAA" ]; then
    # Use the IPv6 update URI for AAAA records
    update_uri="${update_uri6}"
  else
    # Use the IPv4 update URI for other record types
    update_uri="${update_uri4}"
  fi

  action="Update"

  log_to_file "REQ" "${action}" "{\"Request\": \"${domain_full_name}, ${update_uri}, address=${ip_address}\"}"

  # send update request to no-ip.com
  response=$(curl --user "${secret_id}:${secret_key}" \
    -H "User-Agent: ${AGENT}" \
    "https://${update_uri}/nic/update?hostname=${domain_full_name}&myip=${ip_address}")

  # Remove carriage return characters from the response
  response=$(echo "${response}" | tr -d '\r')

  log_to_file "ACK" "${action}" "{\"Response\": \"${response}\"}"

  # If return nochg, it means the local DNS cache is out of date
  if [ "${response}" = "nochg ${ip_address}" ]; then
    logger -p info -s -t "${TAG}" "${domain_full_name} cache of ${ip_version} address ${ip_address} is up to date"
    return 1
  fi

  if [ "${response}" = "good ${ip_address}" ]; then
    logger -p notice -s -t "${TAG}" "${domain_full_name} ${ip_version} address has been updated to ${ip_address}"
    return 0
  else
    logger -p err -s -t "${TAG}" "${domain_full_name} ${ip_version} address failed to update to ${ip_address}, response: ${response}"
    return 1
  fi
}

main "$@"