#!/bin/bash

create () {
  print_usage() {
    echo ''
    echo 'Usage sudo dess create <@sign> <fqdn> <port> <email> <service>'
    echo "Example sudo dess create @bob bob.example.com 6464 bob@example.com bob"
    exit 1
  }

  if [[ $# -eq 0 ]] ; then
      print_usage
  fi

  if [[ $# -gt 5 ]]; then
      tput setaf 1
      echo 'Too many arguments'
      tput setaf 7
      print_usage
  fi

  export env ATSIGN=$1
  export env FQDN=$2
  export env PORT=$3
  export env EMAIL=$4
  export env SERVICE=$5

  error_exit() {
    exit_msg=""
    case "$1" in
      1)exit_msg="Error: certbot failed to get a certificate.";;
      2)exit_msg="Error: failed to pull the root CA file";;
      3)exit_msg="Error: failed to setup the docker compose file";;
      4)exit_msg="Error: failed to start the docker service for the secondary";;
      *);;
    esac
    echo "ERROR: $exit_msg"
    exit "$1"
  }

  # Let's make a secret whilst we are here !
  # hashalot should have been installed by now
  export env SECRET=$(head -30 /dev/urandom | openssl sha512 | awk -F'= ' '{print $2}')

  # Check that we have an @ in the @sign
  if [[ ! $ATSIGN  =~ ^@.*$ ]]
  then
      tput setaf 1
      echo "include @ in @sign"
      tput setaf 7
      exit 1
  fi
  # Check that we have at least one . in the FQDN
  if [[ ! $FQDN  =~  ^.*\..*$ ]]
  then
      tput setaf 1
      echo "include . in fqdn"
      tput setaf 7
      print_usage
      exit 1
  fi

  # Check we have a port number over 1024 and less that 65535
  if [[ ! (($PORT -gt 1024) && ($PORT -lt 65535)) ]]
  then
      tput setaf 1
      echo "Port number not in range 1024-65535"
      tput setaf 7
      print_usage
      exit 1
  fi

  # Check if port number is in use
  ss -tulwn | grep LISTEN |grep ":$PORT " > /dev/null 2>&1
  OPEN=$?
  if [[ $OPEN -eq 0 ]]
  then
      tput setaf 1
      echo "Port number is in use"
      tput setaf 7
      print_usage
      exit 1
  fi

  # Check to make sure we have a valid email
  if [[ ! "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,4}$ ]]
  then
      tput setaf 1
      echo "Invalid email address"
      tput setaf 7
      print_usage
      exit 1
  fi

  # Check to make sure we have a valid service name
  if [[ ! "$SERVICE" =~ ^(([a-zA-Z]|[a-zA-Z][a-zA-Z0-9\-]*[a-zA-Z0-9]))$ ]]
  then
      tput setaf 1
      echo "Invalid service name must comply with DNS for docker service name"
      tput setaf 7
      print_usage
      exit 1
  fi

  command_exists () {
      command -v "$@" > /dev/null 2>&1
  }

  sh_c=''
  change_sh () {
      if command_exists sudo; then
          sh_c="sudo -u $1 sh -c"
      elif command_exists su; then
          sh_c="su -l $1 -c"
      else
          echo 'Error: unable to perform operations as atsign user';
          exit 1
      fi
  }


  # Confirm arguments look valid
  tput setaf 2
  echo "Creating $ATSIGN with $FQDN:$PORT with email $EMAIL with docker service name of $SERVICE"
  tput setaf 7


  change_sh 'atsign'

  # Copy files in from base
  $sh_c "mkdir -p /home/atsign/dess/$ATSIGN"
  $sh_c "cp /home/atsign/base/.env /home/atsign/dess/$ATSIGN"
  $sh_c "cp /home/atsign/base/docker-swarm.yaml /home/atsign/dess/$ATSIGN"
  # Make the edits to the .env file
  # First comment out everything
  $sh_c "sed -i 's/^\([^#].*\)/# \1/g' /home/atsign/dess/$ATSIGN/.env"
  # Add the environment variables we need
  $sh_c "echo ATSIGN=$ATSIGN | tee -a /home/atsign/dess/$ATSIGN/.env"
  $sh_c "echo DOMAIN=$FQDN | tee -a /home/atsign/dess/$ATSIGN/.env"
  $sh_c "echo PORT=$PORT | tee -a /home/atsign/dess/$ATSIGN/.env"
  $sh_c "echo EMAIL=$EMAIL | tee -a /home/atsign/dess/$ATSIGN/.env"
  $sh_c "echo SECRET=$SECRET | tee -a /home/atsign/dess/$ATSIGN/.env"
  # copy over the .env file to base so we can renew the certs with an up to date EMAIL
  $sh_c "cp /home/atsign/dess/$ATSIGN/.env /home/atsign/base/"
  # Get the certificate for the @sign
  tput setaf 2
  echo "Getting certificates"
  tput setaf 7

  change_sh 'root'

  # Make the directories in atsign
  $sh_c "mkdir -p /home/atsign/atsign/$ATSIGN/storage"

  $sh_c "/usr/bin/certbot certonly --standalone --domains $FQDN --non-interactive --agree-tos -m $EMAIL"
  CERTBOT_RESULT=$?
  if [[ $CERTBOT_RESULT -gt 0 ]]; then
      error_exit 1
  fi

  # Last task to put in place the restart script and regenerate the ssl root CA file (as root)
  # Root CA
  $sh_c "curl -L -o  /home/atsign/atsign/etc/live/$FQDN/cacert.pem https://curl.se/ca/cacert.pem"
  CURL_RESULT=$?
  if [[ $CURL_RESULT -gt 0 ]]; then
      error_exit 2
  fi

  # Put some ownership in place so atsign can read the certs
  $sh_c "chown -R atsign:atsign /home/atsign/atsign/$ATSIGN"
  $sh_c "chown -R atsign:atsign /home/atsign/atsign/etc/live/$FQDN"
  $sh_c "chown -R atsign:atsign /home/atsign/atsign/etc/archive/$FQDN"
  # Copy over restart script
  $sh_c "cp /home/atsign/base/restart.sh /home/atsign/atsign/etc/renewal-hooks/deploy"

  # We are now ready to start the secondary !
  tput setaf 2

  # It would be nice to use the @sign for the name but
  # Docker insists on a name that is DNS compliant and so emojis and @ signs are out hence the $SERVICE tag
  # we use a neat trick using docker-compose to create the compose file for us.
  change_sh 'atsign'

  echo Starting secondary for "$ATSIGN" at "$FQDN" on port "$PORT" as "$DNAME" on Docker

  $sh_c "export TMPDIR=/home/atsign/tmp; /usr/bin/docker-compose --env-file /home/atsign/dess/$ATSIGN/.env -f /home/atsign/dess/$ATSIGN/docker-swarm.yaml config | tee /home/atsign/dess/$ATSIGN/docker-compose.yaml > /dev/null;"
  COMPOSE_RESULT=$?
  if [[ $COMPOSE_RESULT -gt 0 ]]; then
      error_exit 3
  fi

  $sh_c "/usr/bin/docker stack deploy -c /home/atsign/dess/$ATSIGN/docker-compose.yaml $SERVICE"
  DOCKER_RESULT=$?
  if [[ $DOCKER_RESULT -gt 0 ]]; then
      error_exit 4
  fi

  echo Your QR-Code for "$ATSIGN"
  tput setaf 7

  qrencode -t ANSIUTF8 "${ATSIGN}:${SECRET}"

}

reshowqr() {
  if [[ $# -eq 0 || $# -gt 1 ]] ; then
    echo 'Usage dess reshowqr <@sign>'
    echo "Example dess reshowqr @bob"
    exit 1
  fi
  if [[ ! -f ~atsign/dess/$1/.env ]]
  then
      echo "Can't find $1, please check for typos."
      exit 2
  fi
  . ~atsign/dess/"$1"/.env
  qrencode -t ANSIUTF8 "${ATSIGN}:${SECRET}"
}

main() {
  subcommand="$1"
  shift
  case "$subcommand" in
    create) create "$@";;
    reshowqr) reshowqr "$@";;
    *)
      echo 'Usage dess <command> [...options]';
      echo 'Available subcommands:';
      echo '  create - create a new dess secondary server';
      echo '  reshowqr - reshow the activate qr for a dess secondary server';
      exit 1;
    ;;
  esac
  exit 0
}

main "$@"
