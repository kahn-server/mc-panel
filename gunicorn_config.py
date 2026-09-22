bind = "0.0.0.0:8080"
workers = 1
worker_class = "eventlet"
certfile = "certs/cert.pem"
keyfile = "certs/key.pem"
proxy_protocol = True
proxy_allow_ips = "127.0.0.1"
accesslog = "-"
