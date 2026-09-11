on run
    try
        do shell script "/usr/bin/pgrep -x DeskPulse"
        open location "deskpulse://hdmi"
    on error
        do shell script "/usr/bin/open -na '/Applications/DeskPulse.app' --args --hdmi"
    end try
end run
