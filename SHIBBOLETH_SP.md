---
title: Shibboleth SP (Debian)
description: SAML Authentication using Shibboleth
category: documentation
---

This document describes installing Shibboleth on Debian 9.

### Shibboleth

    $ sudo apt-get install libapache2-mod-shib2
    $ sudo shib-keygen

Modify `/etc/shibboleth/shibboleth2.xml`:

* Set entityID to `https://vpn.example.org/shibboleth` in the 
  `<ApplicationDefaults>` element.
* Set `handlerSSL` to `true` and `cookieProps` to `https` in the `<Sessions>` 
  element
* Set the `entityID` to the entity ID of your IdP, or configure the 
  `discoveryURL` in the `<SSO>` element
* Remove `SAML1` from the `<SSO>` attribute content as we no longer need SAML 
  1.0 support
* Set the `file` in the `<MetadataProvider>` element for a simple static 
  metadata file

Configuring automatic metadata refresh is outside the scope of this document,
refer to your identity federation documentation.

Verify the Shibboleth configuration:

    $ sudo shibd -t
    overall configuration is loadable, check console for non-fatal problems

Restart Shibboleth:

    $ sudo systemctl restart shibd

Next: register your SP in your identity federation, or in your IdP. The 
metadata URL is typically `https://vpn.example.org/Shibboleth.sso/Metadata`.

### Apache

In `/etc/apache2/sites-available/vpn.example.org.conf` add the following:

    <VirtualHost *:443>

        ...

        <Location /vpn-user-portal>
            AuthType shibboleth
            ShibRequestSetting requireSession true
            Require shibboleth
        </Location>

        # disable Shibboleth for the API
        <Location /vpn-user-portal/api.php>
            ShibRequireSession Off
        </Location>

        # disable Shibboleth for the OAuth Token Endpoint
        <Location /vpn-user-portal/oauth.php>
            ShibRequireSession Off
        </Location> 

        ...

    </VirtualHost>

Make sure you restart Apache after changing the configuration:

    $ sudo systemctl restart apache2

### Portal

In order to configure the VPN portal, modify `/etc/vpn-user-portal/config.php`
and set the `authMethod` and `ShibAuthentication` options:

    ...

    'authMethod' => 'ShibAuthentication',

    ...

    'ShibAuthentication' => [
        'userIdAttribute' => 'persistent-id',
        'permissionAttribute' => 'entitlement',
    ],

    ...

The mentioned attributes `persistent-id` and `entitlement` are configured in 
the Shibboleth configuration. Modify/add others as required in 
`/etc/shibboleth/attribute-map.xml`. Do not forget to restart Shibboleth if
you make any changes to its configuration.
