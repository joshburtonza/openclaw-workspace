#!/bin/bash
# keychain-setup.sh
# Run this ONCE to store your flight booking credentials in macOS Keychain.
# Run it yourself in Terminal — details never touch any log or file.
#
# Usage: bash keychain-setup.sh

echo "=== Amalfi AI Flight Booking — Keychain Setup ==="
echo ""
echo "Enter your details. Nothing is logged or stored in files."
echo ""

read -p  "Full name (as on ID):        " FULL_NAME
read -p  "SA ID number:                " ID_NUMBER
read -p  "Card number (no spaces):     " CARD_NUMBER
read -p  "Card expiry (MM/YY):         " CARD_EXPIRY
read -sp "CVV:                         " CARD_CVV
echo ""
read -p  "Cardholder name on card:     " CARD_NAME
read -p  "Email for bookings:          " BOOKING_EMAIL
read -p  "Phone for bookings:          " BOOKING_PHONE

# Store each field as a separate Keychain entry
security add-generic-password -U -a "full_name"      -s "amalfiai-flights" -w "$FULL_NAME"
security add-generic-password -U -a "id_number"      -s "amalfiai-flights" -w "$ID_NUMBER"
security add-generic-password -U -a "card_number"    -s "amalfiai-flights" -w "$CARD_NUMBER"
security add-generic-password -U -a "card_expiry"    -s "amalfiai-flights" -w "$CARD_EXPIRY"
security add-generic-password -U -a "card_cvv"       -s "amalfiai-flights" -w "$CARD_CVV"
security add-generic-password -U -a "card_name"      -s "amalfiai-flights" -w "$CARD_NAME"
security add-generic-password -U -a "booking_email"  -s "amalfiai-flights" -w "$BOOKING_EMAIL"
security add-generic-password -U -a "booking_phone"  -s "amalfiai-flights" -w "$BOOKING_PHONE"

echo ""
echo "Stored. Run 'security find-generic-password -a full_name -s amalfiai-flights -w' to verify."
