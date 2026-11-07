  "wildcard-example-com-a" = {
    name = "*.example.com"
    type = "A"
    ttl  = 300
    records = ["100.64.0.1"]
  }
  "dmarc-example-com-txt" = {
    name = "_dmarc.example.com"
    type = "TXT"
    ttl  = 3600
    records = ["v=DMARC1; p=none; rua=mailto:dmarc@example.com"]
  }
  "app-example-com-a" = {
    name = "app.example.com"
    type = "A"
    alias = {
      name                   = "d111.cloudfront.example.net"
      zone_id                = "Z0000000000000000000"
      evaluate_target_health = false
    }
  }
  "autodiscover-example-com-cname" = {
    name = "autodiscover.example.com"
    type = "CNAME"
    ttl  = 3600
    records = ["autodiscover.mail.example.net"]
  }
  "example-com-mx" = {
    name = "example.com"
    type = "MX"
    ttl  = 3600
    records = ["0 example-com.mail.example.net."]
  }
  "example-com-txt" = {
    name = "example.com"
    type = "TXT"
    ttl  = 3600
    records = ["v=spf1 include:spf.example.net -all", "MS=ms00000000"]
  }
  "k1-domainkey-example-com-txt" = {
    name = "k1._domainkey.example.com"
    type = "TXT"
    ttl  = 300
    records = ["v=DKIM1; k=rsa; p=AAAAAAAA\"\"BBBBBBBB"]
  }
  "quote-example-com-txt" = {
    name = "quote.example.com"
    type = "TXT"
    ttl  = 300
    records = ["say \\\"hi\\\" $${x}"]
  }
