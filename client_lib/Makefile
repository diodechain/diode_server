
.PHONY: connect
connect: device_certificate.pem
	openssl s_client -connect localhost:41045 -showcerts -msg -servername local -tls1_2 -tlsextdebug -curves secp256k1 -cert device_certificate.pem

device_certificate.pem: secp256k1_params.pem
	openssl req -newkey ec:./secp256k1_params.pem -nodes -keyout device_certificate.pem -x509 -days 365 -out device_certificate.pem -subj "/CN=device"

secp256k1_params.pem:
	openssl ecparam -name secp256k1 -out secp256k1_params.pem
