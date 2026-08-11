# You Should be able to Copy and Paste this into a powershell terminal and it should just work.
# To cleanly exit the server:
#   1. Visit http://localhost:8080/quit in your browser, OR
#   2. Press Ctrl+C in the terminal

# Http Server
$http = New-Object System.Net.HttpListener

# Hostname and port to listen on
$http.Prefixes.Add("http://localhost:8080/")

# Start the Http Server 
$http.Start()

# Log ready message to terminal 
if ($http.IsListening) {
    Write-Host " HTTP Server Ready!  " -f 'black' -b 'gre'
    Write-Host "try testing the different route examples: " -f 'y'
    Write-Host "$($http.Prefixes)" -f 'y'
    Write-Host "$($http.Prefixes)some/form" -f 'y'
    Write-Host "$($http.Prefixes)quit (to stop server)" -f 'y'
    Write-Host "`nPress Ctrl+C to stop the server" -f 'cyan'
}

# Used to cleanly stop the server
try {

# INFINTE LOOP
# Used to listen for requests
while ($http.IsListening) {

    # Get Request Url
    # When a request is made in a web browser the GetContext() method will return a request object
    # Our route examples below will use the request object properties to decide how to respond
    $context = $http.GetContext()


    # ROUTE EXAMPLE 1
    # http://127.0.0.1/
    if ($context.Request.HttpMethod -eq 'GET' -and $context.Request.RawUrl -eq '/') {

        # We can log the request to the terminal
        Write-Host "$($context.Request.UserHostAddress)  =>  $($context.Request.Url)" -f 'mag'

        # the html/data you want to send to the browser
        [string]$html = "<h1>A Powershell Webserver</h1><p>home page</p>" 

        #resposed to the request
        $buffer = [System.Text.Encoding]::UTF8.GetBytes($html) # convert htmtl to bytes
        $context.Response.ContentLength64 = $buffer.Length
        $context.Response.OutputStream.Write($buffer, 0, $buffer.Length) #stream to broswer
        $context.Response.OutputStream.Close() # close the response
    
    }



    # ROUTE EXAMPLE 2
    # http://localhost:8080/some/form'
    if ($context.Request.HttpMethod -eq 'GET' -and $context.Request.RawUrl -eq '/some/form') {

        # We can log the request to the terminal
        Write-Host "$($context.Request.UserHostAddress)  =>  $($context.Request.Url)" -f 'mag'

        [string]$html = "
        <h1>A Powershell Webserver</h1>
        <form action='/some/post' method='post'>
            <p>A Basic Form</p>
            <p>fullname</p>
            <input type='text' name='fullname'>
            <p>message</p>
            <textarea rows='4' cols='50' name='message'></textarea>
            <br>
            <input type='submit' value='Submit'>
        </form>
        "

        #resposed to the request
        $buffer = [System.Text.Encoding]::UTF8.GetBytes($html) 
        $context.Response.ContentLength64 = $buffer.Length
        $context.Response.OutputStream.Write($buffer, 0, $buffer.Length) 
        $context.Response.OutputStream.Close()
    }

    # ROUTE EXAMPLE 3
    # http://localhost:8080/some/post'
    if ($context.Request.HttpMethod -eq 'POST' -and $context.Request.RawUrl -eq '/some/post') {

        # decode the form post
        # html form members need 'name' attributes as in the example!
        $FormContent = [System.IO.StreamReader]::new($context.Request.InputStream).ReadToEnd()

        # We can log the request to the terminal
        Write-Host "$($context.Request.UserHostAddress)  =>  $($context.Request.Url)" -f 'mag'
        Write-Host $FormContent -f 'Green'

        # the html/data
        [string]$html = "<h1>A Powershell Webserver</h1><p>Post Successful!</p>" 

        #resposed to the request
        $buffer = [System.Text.Encoding]::UTF8.GetBytes($html)
        $context.Response.ContentLength64 = $buffer.Length
        $context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
        $context.Response.OutputStream.Close() 
    }

    # ROUTE EXAMPLE 4
    # http://localhost:8080/quit'
    if ($context.Request.HttpMethod -eq 'GET' -and $context.Request.RawUrl -eq '/quit') {
        # Send response before closing
        [string]$html = "<h1>Server Shutting Down...</h1><p>The server has been stopped.</p>"
        $buffer = [System.Text.Encoding]::UTF8.GetBytes($html)
        $context.Response.ContentLength64 = $buffer.Length
        $context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
        $context.Response.OutputStream.Close()

        Write-Host "`nShutting down server..." -f 'yellow'
        $http.Stop()
        $http.Close()
        break
    }

    # powershell will continue looping and listen for new requests...

}

}
finally {
    # Cleanup - ensure the HTTP listener is properly closed
    if ($http.IsListening) {
        Write-Host "`nCleaning up HTTP listener..." -f 'yellow'
        $http.Stop()
    }
    $http.Close()
    Write-Host "HTTP Server stopped." -f 'green'
}
