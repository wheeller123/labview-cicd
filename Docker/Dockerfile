FROM nationalinstruments/labview:latest-windows

# Configure PowerShell for automated installation
SHELL ["powershell", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

# Download VIPM directly from the public GitHub repository (using the raw URL)
RUN Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/wheeller123/LabView-Tools/main/vipm-26.1.3772-windows-setup.exe' -OutFile 'C:\vipm-setup.exe' ; \
    Start-Process -Wait -FilePath 'C:\vipm-setup.exe' -ArgumentList '/quiet', '/norestart' ; \
    Remove-Item 'C:\vipm-setup.exe' -Force

# Add VIPM to PATH
RUN $vipmPath = 'C:\Program Files\JKI\VIPM'; \
    [Environment]::SetEnvironmentVariable('PATH', $env:PATH + ';' + $vipmPath, 'Machine')

# Verify VIPM installation
RUN vipm version
RUN vipm --version


SHELL ["cmd", "/S", "/C"]

CMD ["powershell"]