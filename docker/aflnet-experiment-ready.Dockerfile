FROM mcfuzz-aflnet-experiment:latest

WORKDIR /work
COPY . /work

RUN make deps

CMD ["bash"]
