#!/bin/bash

# Define server details
HOST1=
HOST2=
PASSWORD=

# Array of users to migrate
USERS=("arjun" "admin" "gautam")

# Loop through each user and run imapsync
for user in "${USERS[@]}"; do
    echo "Starting migration for user: $user@xettigar.com"
    
    imapsync \
        --host1 "$HOST1" \
        --user1 "$user@xettigar.com" \
        --password1 "$PASSWORD" \
        --host2 "$HOST2" \
        --user2 "$user@xettigar.com" \
        --password2 "$PASSWORD" \
        --port2 993 \
        --ssl1 \
        --ssl2

    echo "Completed migration for user: $user@xettigar.com"
    echo "----------------------------------------"
done