# TGT_Monitor
This script continuously monitors cache for new TGTs and displays them on the screen (admin privs required)

The retrieved TGTs are encrypted and stored in the system's registry. When you execute the script, you will provide a password that will be used to encrypt and decrypt TGTs stored in the registry.

### Load in memory

```
iex(new-object net.webclient).downloadstring('https://raw.githubusercontent.com/Leo4j/TGT_Monitor/main/TGT_Monitor.ps1')
```

### Start Monitoring

```
TGT_Monitor -EncryptionKey "YourSecurePassword"
```

### Monitor for a specific time (sec)

```
TGT_Monitor -EncryptionKey "YourSecurePassword" -Timeout 10
```

### Read Tickets from registry

```
TGT_Monitor -EncryptionKey "YourSecurePassword" -Read
```

### Clear TGTs previously saved in Registry

```
TGT_Monitor -Clear
```
