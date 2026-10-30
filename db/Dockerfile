FROM postgres:16-alpine

# Skrip di folder ini dieksekusi sekali saat database pertama kali dibuat.
COPY init/ /docker-entrypoint-initdb.d/
