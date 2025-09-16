#!/bin/bash

# Generate self-signed certificate for production use
# WARNING: This certificate is ONLY for local network access!
# DO NOT use this certificate for public internet deployment!

echo "🔒 Generating self-signed certificate for production..."
echo "⚠️  WARNING: This certificate is ONLY for local network access!"
echo "⚠️  DO NOT use this certificate for public internet deployment!"
echo ""

# Create cert directory if it doesn't exist
mkdir -p priv/cert

# Generate private key
openssl genrsa -out priv/cert/prod_key.pem 4096

# Generate certificate signing request and certificate in one step
openssl req -new -x509 -key priv/cert/prod_key.pem -out priv/cert/prod_cert.pem -days 365 \
  -subj "/C=US/ST=Local/L=Local/O=Reencodarr/OU=Local Development/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,DNS:*.local,IP:127.0.0.1,IP:192.168.1.1,IP:10.0.0.1"

echo ""
echo "✅ Production certificate generated successfully!"
echo ""
echo "📁 Files created:"
echo "   - priv/cert/prod_key.pem (private key)"
echo "   - priv/cert/prod_cert.pem (certificate)"
echo ""
echo "🌐 To use HTTPS in production, set these environment variables:"
echo "   export REENCODARR_SSL_CERT_PATH=\"priv/cert/prod_cert.pem\""
echo "   export REENCODARR_SSL_KEY_PATH=\"priv/cert/prod_key.pem\""
echo "   export REENCODARR_ENABLE_SSL=\"true\""
echo ""
echo "⚠️  SECURITY NOTICE:"
echo "   - This certificate is self-signed and will show browser warnings"
echo "   - Only use this for local network access (LAN/home network)"
echo "   - For public internet deployment, get a proper certificate from:"
echo "     * Let's Encrypt (free): https://letsencrypt.org"
echo "     * Your domain provider"
echo "     * A commercial certificate authority"
echo ""
