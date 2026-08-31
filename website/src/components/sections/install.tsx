import { Button } from "@/components/ui/button"
import { GithubIcon } from "@/components/github-icon"
import { APPLE_CONTAINER_URL, RELEASES_URL } from "@/lib/site"

export function Install() {
  return (
    <section
      id="install"
      className="mx-auto max-w-[1180px] scroll-mt-[58px] px-6 pt-[110px] sm:px-8"
    >
      <div data-reveal className="text-center">
        <h2 className="mb-[18px] text-[34px] font-semibold tracking-[-0.03em] sm:text-[44px]">
          Install it
        </h2>
        <p className="mx-auto mb-9 max-w-[48ch] text-sm leading-[1.8] text-pretty text-muted-foreground">
          Requires macOS 26 on Apple silicon and the{" "}
          <a
            href={APPLE_CONTAINER_URL}
            target="_blank"
            rel="noreferrer"
            className="text-foreground underline decoration-dimmer underline-offset-4 transition-colors hover:decoration-foreground"
          >
            container
          </a>{" "}
          CLI installed. The app will not install a runtime for you.
        </p>
        <Button
          asChild
          className="h-auto gap-3.5 rounded-[9px] px-[26px] py-[17px] text-[13.5px] font-semibold hover:bg-[#3e92ff]"
        >
          <a href={RELEASES_URL} target="_blank" rel="noreferrer">
            <GithubIcon className="size-4" />
            Download from GitHub Releases
          </a>
        </Button>
        <p className="mt-[22px] text-[11.5px] text-dimmer">
          Signed .dmg · Apple silicon only
        </p>
      </div>
    </section>
  )
}
