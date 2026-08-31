import { PRINCIPLES } from "@/lib/site"

export function Principles() {
  return (
    <section
      id="what"
      className="mx-auto max-w-[1180px] scroll-mt-[58px] px-6 pt-[110px] sm:px-8"
    >
      <h2 className="sr-only">What Container GUI is</h2>
      <div data-reveal className="grid gap-12 md:grid-cols-3 md:gap-14">
        {PRINCIPLES.map((principle) => (
          <div key={principle.index}>
            <h3 className="mb-4 text-[11px] tracking-[0.14em] text-primary uppercase">
              {principle.index} — {principle.title}
            </h3>
            <p className="text-sm leading-[1.8] text-pretty text-muted-foreground">
              {principle.body}
            </p>
          </div>
        ))}
      </div>
    </section>
  )
}
